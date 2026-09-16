-- Does the transmit chain still batch when consecutive packets belong to
-- different sockets?
--
-- tb_w5500_tx answers "are the bytes right" but drives socket 0 only, so it
-- cannot see the failure that made the eight-socket spread measure *slower*
-- than one hot socket: the datagram being accumulated was tracked once, not per
-- socket, so a packet for a different socket closed it. The output arbiter in
-- metric_packet_manager re-checks priority after every packet, so spread
-- traffic alternates sockets almost every packet and every datagram went out
-- holding exactly one metric -- paying the full nine-transaction SEND overhead
-- per packet while appearing to batch.
--
-- The same behavioural W5500 as tb_w5500_tx sits on the SPI pins, with a
-- transmit buffer and an expected-sequence counter per socket, so a record that
-- lands in the wrong socket's datagram is caught rather than merely counted.
--
--   G_SOCKETS  sockets the source round-robins over
--   G_BATCH    packets accumulated before SEND (TX_BATCH_MAX_PACKETS)
--   G_PACKETS  packets fed in total, spread evenly over the sockets
--   G_GAP      idle clocks between packets; 0 = back-to-back
--
-- Acceptance is two-sided. Correctness: every record arrives, in its own
-- socket's datagram, in order. Efficiency: records per datagram must reach at
-- least half of G_BATCH -- with one batch tracked globally it is exactly 1.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_w5500_tx_multisocket is
  generic (
    G_SOCKETS : integer := 8;
    G_BATCH   : integer := 16;
    G_PACKETS : integer := 256;
    G_GAP     : integer := 0;
    -- Mid-packet starvation, as in tb_w5500_tx: drop tvalid for G_STALL clocks
    -- after byte G_STALL_AT of every packet.
    G_STALL    : integer := 0;
    G_STALL_AT : integer := 4;
    G_TRACE    : integer := 0;   -- 1 = log every datagram
    G_TX_FIXED_NS : integer := 5000;
    -- Starvation mode. One packet goes to the highest socket, then socket 0 is
    -- saturated for the rest of the run. The arbiter upstream is strict
    -- lowest-index-first, so on hardware that high socket would get no further
    -- traffic at all while socket 0 has any -- and its part-filled datagram must
    -- still leave the chip, rather than waiting for companions that the arbiter
    -- will never deliver.
    G_STARVE : integer := 0;
    -- Longest the starved socket's datagram may take to leave the chip, from the
    -- moment its packet was offered. Generous next to the design's own ceiling
    -- (TX_MAX_OPEN_CLKS, 273 us at 30 MHz) because the escape is only tested
    -- when the machine passes back through its idle check; the point is to
    -- separate "bounded" from "waits for the load to stop", not to pin the exact
    -- figure.
    G_STARVE_BOUND_US : integer := 1000
  );
end entity;

architecture sim of tb_w5500_tx_multisocket is

  constant CLK_PERIOD : time := 33333 ps;   -- 30 MHz, as on the board
  constant PKT_BYTES  : integer := 9;
  constant TXBUF_SIZE : integer := 2048;    -- W5500 default per socket

  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';

  signal mosi, miso, sclk, cs : std_logic;
  signal spi_busy : std_logic;

  signal tdata, rdata : std_logic_vector(7 downto 0);
  signal tvalid, tready, tlast : std_logic;
  signal rvalid, rready, rlast : std_logic;

  signal ext_pl_tdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal ext_pl_tvalid : std_logic := '0';
  signal ext_pl_tready : std_logic;
  signal ext_pl_tlast  : std_logic := '0';
  signal ext_pl_tuser  : std_logic_vector(2 downto 0) := "000";

  signal ext_pl_rdata  : std_logic_vector(7 downto 0);
  signal ext_pl_rvalid : std_logic;
  signal ext_pl_rready : std_logic := '1';
  signal ext_pl_rlast  : std_logic;
  signal ext_pl_ruser  : std_logic_vector(2 downto 0);

  signal n_datagrams  : integer := 0;
  signal n_bytes_out  : integer := 0;
  signal n_records    : integer := 0;
  signal n_bad_len    : integer := 0;
  signal n_bad_rec    : integer := 0;
  signal n_fed        : integer := 0;
  signal n_send_drop  : integer := 0;
  signal n_buf_writes : integer := 0;
  -- Most records any single datagram carried. With the batch tracked globally
  -- this never exceeds 1 once the sockets alternate.
  signal max_in_dgram : integer := 0;
  signal cs_idle_max  : integer := 0;
  signal feed_done    : std_logic := '0';
  -- Wall-clock the source needed to hand over every packet. The source offers
  -- data continuously, so this is paced by how fast the transmit chain accepts
  -- it and is the service rate the batching is meant to raise.
  signal feed_ns      : integer := 0;
  -- When the source began, and when the highest socket's datagram was first
  -- sent. The gap between them is how long a starved socket's data sat in the
  -- chip while socket 0 monopolised the stream.
  signal feed_start_ns   : integer := 0;
  signal starved_sent_ns : integer := -1;

  -- Packet content: socket in byte 3 so a record delivered on the wrong
  -- socket's datagram is identifiable, sequence in bytes 4-5.
  function pkt_byte(sock : integer; i : integer; b : integer)
    return std_logic_vector is
  begin
    case b is
      when 0 => return x"56";                                    -- 'V'
      when 1 => return x"30";                                    -- '0'
      when 2 => return x"31";                                    -- '1'
      when 3 => return std_logic_vector(to_unsigned(sock, 8));
      when 4 => return std_logic_vector(to_unsigned(i / 256, 8));
      when 5 => return std_logic_vector(to_unsigned(i mod 256, 8));
      when 6 => return x"A5";
      when 7 => return std_logic_vector(to_unsigned((sock * 31 + i) mod 256, 8));
      when others => return std_logic_vector(to_unsigned(i mod 256, 8));
    end case;
  end function;

  function hex(v : std_logic_vector(7 downto 0)) return string is
    constant D : string := "0123456789ABCDEF";
    variable u : integer := to_integer(unsigned(v));
  begin
    return D(u / 16 + 1) & D(u mod 16 + 1);
  end function;

begin

  clk <= not clk after CLK_PERIOD / 2;

  reset_proc : process
  begin
    reset <= '1';
    wait for 20 * CLK_PERIOD;
    wait until rising_edge(clk);
    reset <= '0';
    wait;
  end process;

  dut_fsm : entity work.w5500_state_machine
    generic map (
      socket_amount        => G_SOCKETS,
      DEFAULT_ROUTINE      => "send_first",
      TX_BATCH_MAX_PACKETS => G_BATCH
    )
    port map (
      clk => clk, reset => reset, spi_busy => spi_busy,
      tdata => tdata, tvalid => tvalid, tready => tready, tlast => tlast,
      rdata => rdata, rvalid => rvalid, rready => rready, rlast => rlast,
      ext_pl_tdata => ext_pl_tdata, ext_pl_tready => ext_pl_tready,
      ext_pl_tvalid => ext_pl_tvalid, ext_pl_tlast => ext_pl_tlast,
      ext_pl_tuser => ext_pl_tuser,
      ext_pl_rdata => ext_pl_rdata, ext_pl_rready => ext_pl_rready,
      ext_pl_rvalid => ext_pl_rvalid, ext_pl_rlast => ext_pl_rlast,
      ext_pl_ruser => ext_pl_ruser);

  dut_spi : entity work.spi_master
    port map (
      tdata => tdata, rdata => rdata,
      mosi => mosi, miso => miso, sclk => sclk, cs => cs,
      clk => clk, reset => reset, spi_busy => spi_busy,
      tvalid => tvalid, tready => tready, tlast => tlast,
      rvalid => rvalid, rready => rready, rlast => rlast);

  ---------------------------------------------------------------------------
  -- Behavioural W5500, with per-socket transmit buffer and expectations
  ---------------------------------------------------------------------------
  w5500 : process
    type buf_t is array (0 to 8 * TXBUF_SIZE - 1) of std_logic_vector(7 downto 0);
    type ptr_t is array (0 to 7) of integer;
    type reg_t is array (0 to 7) of std_logic_vector(7 downto 0);

    variable txbuf     : buf_t := (others => x"00");
    variable tx_wr     : ptr_t := (others => 0);   -- Sn_TX_WR
    variable sent_upto : ptr_t := (others => 0);   -- what SEND has already taken
    variable sn_ir     : reg_t := (others => x"00");
    -- Next sequence number expected on each socket, independently.
    variable expect    : ptr_t := (others => 0);
    variable tx_done_at : time := 0 ns;

    variable rxbyte  : std_logic_vector(7 downto 0) := (others => '0');
    variable txbyte  : std_logic_vector(7 downto 0) := (others => '0');
    variable bytecnt : integer := 0;
    variable addr    : integer := 0;
    variable ctrl    : std_logic_vector(7 downto 0) := (others => '0');
    variable sock    : integer := 0;
    variable blk     : integer := 0;      -- BSB low 2 bits: 1 = reg, 2 = tx, 3 = rx
    variable is_wr   : boolean := false;
    variable off     : integer := 0;

    variable pending : integer := 0;
    variable bad_rec : integer := 0;
    variable rec_ok  : boolean;

    impure function reg_read(k : integer) return std_logic_vector is
      variable free_sz : integer;
    begin
      if blk = 1 then
        case addr is
          when 16#0020# =>                                     -- Sn_TX_FSR
            free_sz := TXBUF_SIZE - ((tx_wr(sock) - sent_upto(sock)) mod 65536);
            if k = 0 then
              return std_logic_vector(to_unsigned(free_sz / 256, 8));
            else
              return std_logic_vector(to_unsigned(free_sz mod 256, 8));
            end if;
          when 16#0024# =>                                     -- Sn_TX_WR
            if k = 0 then
              return std_logic_vector(to_unsigned(tx_wr(sock) / 256, 8));
            else
              return std_logic_vector(to_unsigned(tx_wr(sock) mod 256, 8));
            end if;
          when 16#0002# =>                                     -- Sn_IR
            if now >= tx_done_at then
              return sn_ir(sock) or x"10";                     -- SEND_OK
            else
              return sn_ir(sock);
            end if;
          when 16#0003# => return x"22";                       -- Sn_SR = SOCK_UDP
          when others   => return x"00";                       -- nothing staged to receive
        end case;
      end if;
      return x"00";
    end function;
  begin
    miso <= '0';

    loop
      wait until falling_edge(cs);
      bytecnt := 0;
      off     := 0;

      byte_loop : loop
        if bytecnt >= 3 and not is_wr then
          txbyte := reg_read(bytecnt - 3);
        else
          txbyte := x"00";
        end if;

        for b in 7 downto 0 loop
          miso <= txbyte(b);
          wait until rising_edge(sclk) or rising_edge(cs);
          exit byte_loop when cs = '1';
          rxbyte := rxbyte(6 downto 0) & to_x01(mosi);
          wait until falling_edge(sclk) or rising_edge(cs);
          exit byte_loop when cs = '1';
        end loop;

        case bytecnt is
          when 0 => addr := to_integer(unsigned(rxbyte)) * 256;
          when 1 => addr := addr + to_integer(unsigned(rxbyte));
          when 2 =>
            ctrl  := rxbyte;
            sock  := to_integer(unsigned(ctrl(7 downto 5)));
            blk   := to_integer(unsigned(ctrl(4 downto 3)));
            is_wr := ctrl(2) = '1';
          when others =>
            if is_wr then
              if blk = 2 then                                  -- TX buffer write
                txbuf(sock * TXBUF_SIZE + ((addr + off) mod TXBUF_SIZE)) := rxbyte;
                n_buf_writes <= n_buf_writes + 1;
              elsif blk = 1 then
                case addr is
                  when 16#0024# =>                             -- Sn_TX_WR
                    if off = 0 then
                      tx_wr(sock) := (tx_wr(sock) mod 256) + to_integer(unsigned(rxbyte)) * 256;
                    else
                      tx_wr(sock) := (tx_wr(sock) / 256) * 256 + to_integer(unsigned(rxbyte));
                    end if;
                  when 16#0001# =>                             -- Sn_CR
                    if rxbyte = x"20" and now < tx_done_at then
                      n_send_drop <= n_send_drop + 1;
                      report "SEND dropped: chip busy for another "
                           & time'image(tx_done_at - now) severity warning;
                    elsif rxbyte = x"20" then                  -- SEND
                      pending := (tx_wr(sock) - sent_upto(sock)) mod 65536;
                      tx_done_at := now + (G_TX_FIXED_NS * 1 ns)
                                        + (pending * 80 ns);
                      n_datagrams <= n_datagrams + 1;
                      n_bytes_out <= n_bytes_out + pending;
                      if pending / PKT_BYTES > max_in_dgram then
                        max_in_dgram <= pending / PKT_BYTES;
                      end if;

                      if pending mod PKT_BYTES /= 0 then
                        n_bad_len <= n_bad_len + 1;
                        report "DATAGRAM " & integer'image(n_datagrams)
                             & " on socket " & integer'image(sock)
                             & ": length " & integer'image(pending)
                             & " is not a multiple of " & integer'image(PKT_BYTES)
                          severity warning;
                      end if;

                      bad_rec := 0;
                      for r in 0 to pending / PKT_BYTES - 1 loop
                        rec_ok := true;
                        for b in 0 to PKT_BYTES - 1 loop
                          if txbuf(sock * TXBUF_SIZE
                                   + ((sent_upto(sock) + r * PKT_BYTES + b) mod TXBUF_SIZE))
                             /= pkt_byte(sock, expect(sock), b) then
                            rec_ok := false;
                          end if;
                        end loop;
                        if not rec_ok then
                          bad_rec := bad_rec + 1;
                          if n_bad_rec + bad_rec <= 5 then
                            report "DATAGRAM " & integer'image(n_datagrams)
                                 & " socket " & integer'image(sock)
                                 & " record " & integer'image(r)
                                 & ": expected socket " & integer'image(sock)
                                 & " seq " & integer'image(expect(sock))
                                 & ", got sock byte "
                                 & hex(txbuf(sock * TXBUF_SIZE + ((sent_upto(sock) + r * PKT_BYTES + 3) mod TXBUF_SIZE)))
                                 & " seq "
                                 & hex(txbuf(sock * TXBUF_SIZE + ((sent_upto(sock) + r * PKT_BYTES + 4) mod TXBUF_SIZE)))
                                 & hex(txbuf(sock * TXBUF_SIZE + ((sent_upto(sock) + r * PKT_BYTES + 5) mod TXBUF_SIZE)))
                              severity warning;
                          end if;
                        end if;
                        expect(sock) := expect(sock) + 1;
                      end loop;

                      n_records <= n_records + pending / PKT_BYTES;
                      n_bad_rec <= n_bad_rec + bad_rec;

                      if G_TRACE = 1 then
                        report "datagram " & integer'image(n_datagrams)
                             & ": socket " & integer'image(sock)
                             & ", " & integer'image(pending) & " bytes"
                             & ", " & integer'image(pending / PKT_BYTES) & " records"
                             & ", " & integer'image(bad_rec) & " bad"
                          severity note;
                      end if;

                      if sock = G_SOCKETS - 1 and starved_sent_ns < 0 then
                        starved_sent_ns <= now / 1 ns;
                      end if;

                      sent_upto(sock) := tx_wr(sock);
                      sn_ir(sock) := sn_ir(sock) or x"10";     -- SEND_OK
                    end if;
                  when 16#0002# =>                             -- Sn_IR: write 1 clears
                    sn_ir(sock) := sn_ir(sock) and not rxbyte;
                  when others => null;
                end case;
              end if;
            end if;
            off := off + 1;
        end case;

        bytecnt := bytecnt + 1;
      end loop;
    end loop;
  end process;

  ---------------------------------------------------------------------------
  -- Metric source: round-robin over the sockets, each with its own sequence
  ---------------------------------------------------------------------------
  feed : process
    variable sock : integer := 0;
    variable seq  : integer := 0;
    variable t0   : time := 0 ns;
  begin
    ext_pl_tvalid <= '0';
    ext_pl_tlast  <= '0';
    wait until reset = '0';
    -- let the chip-init pipeline run to completion before offering anything
    wait for 400 us;
    wait until rising_edge(clk);
    t0 := now;
    feed_start_ns <= now / 1 ns;

    for i in 0 to G_PACKETS - 1 loop
      if G_STARVE = 1 then
        if i = 0 then
          sock := G_SOCKETS - 1;      -- the one packet the starved socket gets
          seq  := 0;
        else
          sock := 0;                  -- and then nothing but socket 0
          seq  := i - 1;
        end if;
      else
        sock := i mod G_SOCKETS;
        seq  := i / G_SOCKETS;
      end if;
      ext_pl_tuser <= std_logic_vector(to_unsigned(sock, 3));

      for b in 0 to PKT_BYTES - 1 loop
        ext_pl_tdata  <= pkt_byte(sock, seq, b);
        ext_pl_tvalid <= '1';
        if b = PKT_BYTES - 1 then
          ext_pl_tlast <= '1';
        else
          ext_pl_tlast <= '0';
        end if;
        loop
          wait until rising_edge(clk);
          exit when ext_pl_tready = '1';
        end loop;

        if G_STALL > 0 and b = G_STALL_AT then
          ext_pl_tvalid <= '0';
          ext_pl_tlast  <= '0';
          for g in 1 to G_STALL loop
            wait until rising_edge(clk);
          end loop;
        end if;
      end loop;
      n_fed <= i + 1;

      if G_GAP > 0 then
        ext_pl_tvalid <= '0';
        ext_pl_tlast  <= '0';
        for g in 1 to G_GAP loop
          wait until rising_edge(clk);
        end loop;
      end if;
    end loop;

    ext_pl_tvalid <= '0';
    ext_pl_tlast  <= '0';
    feed_ns   <= (now - t0) / 1 ns;
    feed_done <= '1';
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- Liveness: how long does the bus stay quiet?
  ---------------------------------------------------------------------------
  liveness : process
    variable idle : integer := 0;
  begin
    wait until reset = '0';
    wait for 500 us;
    loop
      wait until rising_edge(clk);
      if cs = '0' then
        idle := 0;
      else
        idle := idle + 1;
        if idle > cs_idle_max then
          cs_idle_max <= idle;
        end if;
      end if;
    end loop;
  end process;

  ---------------------------------------------------------------------------
  -- Report
  ---------------------------------------------------------------------------
  reporter : process
    variable per_dgram_x10 : integer := 0;
    -- Microseconds from the source offering the starved socket's packet to that
    -- socket's datagram being sent; -1 if it never was.
    variable starved_lat_us : integer := -1;
    variable starved_ok     : boolean := false;
  begin
    wait until feed_done = '1';
    -- long enough for every socket's idle-gap flush to fire and drain
    wait for 10 ms;

    if n_datagrams > 0 then
      per_dgram_x10 := (n_records * 10) / n_datagrams;
    end if;

    if starved_sent_ns >= 0 then
      starved_lat_us := (starved_sent_ns - feed_start_ns) / 1000;
    end if;
    starved_ok := starved_lat_us >= 0
                  and starved_lat_us <= G_STARVE_BOUND_US;

    report "=== tb_w5500_tx_multisocket: sockets=" & integer'image(G_SOCKETS)
         & " batch=" & integer'image(G_BATCH)
         & " packets=" & integer'image(G_PACKETS)
         & " gap=" & integer'image(G_GAP) & " clks"
         & " stall=" & integer'image(G_STALL) & "@" & integer'image(G_STALL_AT)
         & " ===" severity note;
    report "fed        : " & integer'image(n_fed) & " packets, "
         & integer'image(n_fed * PKT_BYTES) & " bytes" severity note;
    report "transmitted: " & integer'image(n_datagrams) & " datagrams, "
         & integer'image(n_bytes_out) & " bytes, "
         & integer'image(n_records) & " records" severity note;
    report "batching   : " & integer'image(per_dgram_x10 / 10) & "."
         & integer'image(per_dgram_x10 mod 10) & " records/datagram"
         & "  (largest datagram " & integer'image(max_in_dgram) & " records"
         & ", batch limit " & integer'image(G_BATCH) & ")" severity note;
    -- Reported rather than asserted on: it is a simulation service rate with a
    -- behavioural chip on the SPI pins, so it belongs in the log as evidence,
    -- not in a pass/fail bound that would encode this model's timing.
    if feed_ns > 0 then
      report "service    : " & integer'image(n_fed) & " packets accepted in "
           & integer'image(feed_ns / 1000) & " us = "
           & integer'image((n_fed * 1000000) / feed_ns) & " kpackets/s"
        severity note;
    end if;
    report "bad lengths: " & integer'image(n_bad_len) severity note;
    report "bad records: " & integer'image(n_bad_rec) severity note;
    report "SEND dropped (chip still transmitting): "
         & integer'image(n_send_drop) severity note;
    report "bytes into TX buffer: " & integer'image(n_buf_writes)
         & "  (Sn_TX_WR advance: " & integer'image(n_bytes_out) & ")" severity note;
    report "longest quiet: " & integer'image(cs_idle_max) & " clks" severity note;
    if G_STARVE = 1 then
      report "starved sock " & integer'image(G_SOCKETS - 1)
           & ": datagram released after " & integer'image(starved_lat_us)
           & " us (bound " & integer'image(G_STARVE_BOUND_US)
           & " us, source ran for " & integer'image(feed_ns / 1000) & " us)"
        severity note;
    end if;

    assert n_buf_writes = n_fed * PKT_BYTES
      report "SPI OVER/UNDER-SHIFT: chip received " & integer'image(n_buf_writes)
           & " bytes for " & integer'image(n_fed * PKT_BYTES) & " fed"
      severity error;
    assert n_bytes_out = n_fed * PKT_BYTES
      report "BYTE COUNT MISMATCH: Sn_TX_WR advanced " & integer'image(n_bytes_out)
           & " bytes for " & integer'image(n_fed * PKT_BYTES) & " bytes written"
      severity error;
    assert n_records = n_fed
      report "RECORD COUNT: " & integer'image(n_records) & " of "
           & integer'image(n_fed) & " fed packets left the chip" severity error;
    assert n_bad_len = 0
      report "MALFORMED DATAGRAM LENGTHS: " & integer'image(n_bad_len) severity error;
    assert n_bad_rec = 0
      report "DISPLACED RECORDS: " & integer'image(n_bad_rec) severity error;
    assert n_send_drop = 0
      report "LOST SEND COMMANDS: " & integer'image(n_send_drop) severity error;
    assert cs_idle_max < 40000
      report "BUS WENT QUIET for " & integer'image(cs_idle_max)
           & " clocks -- the machine parked" severity error;

    -- The point of the test. A continuously fed source must fill its batches
    -- whatever order the sockets arrive in; one record per datagram means the
    -- accumulation is being closed by the socket changing, which is the whole
    -- overhead batching exists to avoid.
    assert per_dgram_x10 >= (G_BATCH * 10) / 2
      report "BATCHING DEFEATED BY SOCKET INTERLEAVE: "
           & integer'image(per_dgram_x10 / 10) & "."
           & integer'image(per_dgram_x10 mod 10)
           & " records per datagram against a batch limit of "
           & integer'image(G_BATCH) severity error;

    -- The other side of that bargain: batching may not hold a quiet socket's
    -- data hostage to a busy one. Waiting until the load stops is not good
    -- enough -- on the board the load does not stop.
    assert G_STARVE = 0 or starved_ok
      report "STARVED SOCKET HELD OPEN: socket "
           & integer'image(G_SOCKETS - 1)
           & " had a part-filled datagram and it took "
           & integer'image(starved_lat_us) & " us to leave the chip (bound "
           & integer'image(G_STARVE_BOUND_US) & " us) -- it is being held open "
           & "by the socket that is saturating the stream" severity error;

    if n_bytes_out = n_fed * PKT_BYTES and n_bad_len = 0 and n_bad_rec = 0
       and n_records = n_fed and n_buf_writes = n_fed * PKT_BYTES
       and n_send_drop = 0 and cs_idle_max < 40000
       and per_dgram_x10 >= (G_BATCH * 10) / 2
       and (G_STARVE = 0 or starved_ok) then
      report "PASS" severity note;
    else
      report "FAIL" severity note;
    end if;
    finish;
  end process;

end architecture;
