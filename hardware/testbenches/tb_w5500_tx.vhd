-- Does the TX chain put into the W5500's transmit buffer exactly the bytes the
-- fabric handed it, and does Sn_TX_WR advance by exactly that many?
--
-- On hardware this can only be inferred from what arrives on the wire, which is
-- why three attempts at batching were debugged blind. Here a behavioural W5500
-- sits on the SPI pins: it decodes the 3-byte header, keeps a register file and
-- a per-socket transmit buffer, and on Sn_CR = SEND publishes the bytes between
-- the previous send and the current Sn_TX_WR -- which is precisely the datagram
-- the chip would put on the wire.
--
-- The source feeds 9-byte 'V01' metric packets carrying their own sequence
-- number, so a duplicated, dropped or displaced byte is identifiable rather
-- than merely visible as a wrong length.
--
--   G_BATCH   packets accumulated before SEND (TX_BATCH_MAX_PACKETS)
--   G_PACKETS packets fed
--   G_GAP     idle clocks between packets; 0 = back-to-back, which is the
--             regime that fails on hardware

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_w5500_tx is
  generic (
    G_BATCH   : integer := 1;
    G_PACKETS : integer := 40;
    G_GAP     : integer := 0;
    -- Mid-packet starvation: drop tvalid for G_STALL clocks after byte
    -- G_STALL_AT of every packet. The fabric source cannot always deliver nine
    -- bytes back-to-back, and the SPI transaction has already started by then.
    G_STALL    : integer := 0;
    G_STALL_AT : integer := 4;
    G_TRACE    : integer := 0;   -- 1 = log every SPI transaction, 2 = every buffer byte
    -- UDP datagrams staged in the chip's receive buffer. The same FIFO sits on
    -- the receive path, so this is the regression that guards it.
    G_RX_PACKETS : integer := 0;
    -- Stage this many bytes in the receive buffer instead of G_RX_PACKETS * 17.
    -- Sn_RX_RSR reaches 2048 when the 2 KB socket buffer is completely full.
    G_RX_FILL : integer := 0;
    -- How long the chip is busy putting a datagram on the wire: this fixed part
    -- plus 80 ns per byte (100 Mbit). A SEND issued while it is still busy is
    -- what the firmware never checks for, because it clears SEND_OK by writing
    -- to Sn_SR, which is read-only.
    G_TX_FIXED_NS : integer := 5000;
    -- Watchdog threshold handed to the state machine. The default matches the
    -- design default; a deliberately tiny value is how the escape path itself
    -- gets exercised.
    G_WATCHDOG : integer := 65535
  );
end entity;

architecture sim of tb_w5500_tx is

  constant CLK_PERIOD : time := 33333 ps;   -- 30 MHz, as on the board
  constant PKT_BYTES  : integer := 9;
  constant TXBUF_SIZE : integer := 2048;    -- W5500 default per socket

  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';

  -- SPI
  signal mosi, miso, sclk, cs : std_logic;
  signal spi_busy : std_logic;

  -- state machine <-> spi master
  signal tdata, rdata : std_logic_vector(7 downto 0);
  signal tvalid, tready, tlast : std_logic;
  signal rvalid, rready, rlast : std_logic;

  -- fabric -> state machine
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

  -- verification counters, driven by the model, read by the reporter
  signal n_datagrams  : integer := 0;
  signal n_bytes_out  : integer := 0;
  signal n_records    : integer := 0;
  signal n_bad_len    : integer := 0;
  signal n_bad_rec    : integer := 0;
  signal n_fed        : integer := 0;
  signal n_rx_records : integer := 0;
  signal n_rx_bad     : integer := 0;
  signal n_send_drop  : integer := 0;
  -- Receive-buffer reads (block select 3). Zero of them while the chip reports
  -- bytes waiting means the machine believes the socket is empty.
  signal n_rx_reads   : integer := 0;
  signal n_spi        : integer := 0;
  -- Longest stretch with chip select idle, in clocks: a machine that has parked
  -- issues no SPI at all, so this is the liveness measure.
  signal cs_idle_max  : integer := 0;
  -- Bytes the chip actually received into its TX buffer. Larger than
  -- n_bytes_out means the SPI master shifted out more than the fabric handed
  -- it -- the underrun duplicate. Smaller means Sn_TX_WR ran ahead of the data.
  signal n_buf_writes : integer := 0;
  signal feed_done    : std_logic := '0';

  -- expected content of packet i, byte b
  function pkt_byte(i : integer; b : integer) return std_logic_vector is
  begin
    case b is
      when 0 => return x"56";                                    -- 'V'
      when 1 => return x"30";                                    -- '0'
      when 2 => return x"31";                                    -- '1'
      when 3 => return std_logic_vector(to_unsigned(i / 256, 8));
      when 4 => return std_logic_vector(to_unsigned(i mod 256, 8));
      when 5 => return x"A5";
      when 6 => return x"5A";
      when 7 => return std_logic_vector(to_unsigned(i / 256, 8));
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
      socket_amount        => 1,
      DEFAULT_ROUTINE      => "send_first",
      TX_BATCH_MAX_PACKETS => G_BATCH,
      WATCHDOG_CLKS        => G_WATCHDOG
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
  -- Behavioural W5500
  ---------------------------------------------------------------------------
  w5500 : process
    type buf_t  is array (0 to 8 * TXBUF_SIZE - 1) of std_logic_vector(7 downto 0);
    type ptr_t  is array (0 to 7) of integer;
    type reg_t  is array (0 to 7) of std_logic_vector(7 downto 0);

    variable txbuf     : buf_t := (others => x"00");
    variable tx_wr     : ptr_t := (others => 0);   -- Sn_TX_WR
    variable sent_upto : ptr_t := (others => 0);   -- what SEND has already taken
    variable sn_ir     : reg_t := (others => x"00");

    variable rxbuf  : buf_t := (others => x"00");
    variable rx_wr  : ptr_t := (others => 0);      -- how much the chip has staged
    variable rx_rd  : ptr_t := (others => 0);      -- Sn_RX_RD
    variable staged : boolean := false;
    variable tx_done_at : time := 0 ns;   -- when the wire is free again

    variable rxbyte  : std_logic_vector(7 downto 0) := (others => '0');
    variable txbyte  : std_logic_vector(7 downto 0) := (others => '0');
    variable bytecnt : integer := 0;
    variable addr    : integer := 0;
    variable ctrl    : std_logic_vector(7 downto 0) := (others => '0');
    variable sock    : integer := 0;
    variable blk     : integer := 0;      -- BSB low 2 bits: 1 = reg, 2 = tx, 3 = rx
    variable is_wr   : boolean := false;
    variable off     : integer := 0;      -- payload byte index within transaction

    variable pending : integer := 0;
    variable expect  : integer := 0;      -- next packet number expected
    variable bad_rec : integer := 0;
    variable rec_ok  : boolean;

    -- read data the chip would drive for payload byte `k` of this transaction
    impure function reg_read(k : integer) return std_logic_vector is
      variable free_sz : integer;
      variable rsr     : integer;
    begin
      if blk = 3 then                                          -- RX buffer read
        return rxbuf(sock * TXBUF_SIZE + ((addr + k) mod TXBUF_SIZE));
      end if;
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
          when 16#0026# =>                                     -- Sn_RX_RSR
            rsr := (rx_wr(sock) - rx_rd(sock)) mod 65536;
            if k = 0 then
              return std_logic_vector(to_unsigned(rsr / 256, 8));
            else
              return std_logic_vector(to_unsigned(rsr mod 256, 8));
            end if;
          when 16#0028# =>                                     -- Sn_RX_RD
            if k = 0 then
              return std_logic_vector(to_unsigned(rx_rd(sock) / 256, 8));
            else
              return std_logic_vector(to_unsigned(rx_rd(sock) mod 256, 8));
            end if;
          when others   => return x"00";
        end case;
      end if;
      return x"00";
    end function;
  begin
    miso <= '0';

    -- Stage receive traffic on socket 0: an 8-byte W5500 receive header
    -- (source IP, source port, payload length) followed by one metric packet,
    -- which is what the chip's buffer holds after a UDP datagram arrives.
    if not staged then
      staged := true;
      for i in 0 to G_RX_PACKETS - 1 loop
        rxbuf(i * 17 + 0) := x"C0";
        rxbuf(i * 17 + 1) := x"A8";
        rxbuf(i * 17 + 2) := x"02";
        rxbuf(i * 17 + 3) := x"6A";
        rxbuf(i * 17 + 4) := x"24";
        rxbuf(i * 17 + 5) := x"01";
        rxbuf(i * 17 + 6) := x"00";
        rxbuf(i * 17 + 7) := std_logic_vector(to_unsigned(PKT_BYTES, 8));
        for b in 0 to PKT_BYTES - 1 loop
          rxbuf(i * 17 + 8 + b) := pkt_byte(i, b);
        end loop;
      end loop;
      if G_RX_FILL > 0 then
        rx_wr(0) := G_RX_FILL;
      else
        rx_wr(0) := G_RX_PACKETS * 17;
      end if;
    end if;

    loop
      wait until falling_edge(cs);
      bytecnt := 0;
      off     := 0;

      byte_loop : loop
        -- what to drive for this byte
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

        -- a complete byte has been shifted in
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
                if G_TRACE = 2 then
                  report "  txbuf[" & integer'image((addr + off) mod TXBUF_SIZE)
                       & "] <= " & hex(rxbyte)
                       & " @" & time'image(now) severity note;
                end if;
              elsif blk = 1 then                               -- socket register
                case addr is
                  when 16#0024# =>                             -- Sn_TX_WR
                    if off = 0 then
                      tx_wr(sock) := (tx_wr(sock) mod 256) + to_integer(unsigned(rxbyte)) * 256;
                    else
                      tx_wr(sock) := (tx_wr(sock) / 256) * 256 + to_integer(unsigned(rxbyte));
                    end if;
                  when 16#0001# =>                             -- Sn_CR
                    if rxbyte = x"20" and now < tx_done_at then -- SEND while busy
                      -- The chip is still putting the previous datagram on the
                      -- wire. The command is lost; the bytes stay in the buffer
                      -- and go out attached to whatever the next SEND covers.
                      n_send_drop <= n_send_drop + 1;
                      report "SEND dropped: chip busy for another "
                           & time'image(tx_done_at - now) severity warning;
                    elsif rxbyte = x"20" then                  -- SEND
                      pending := (tx_wr(sock) - sent_upto(sock)) mod 65536;
                      tx_done_at := now + (G_TX_FIXED_NS * 1 ns)
                                        + (pending * 80 ns);
                      n_datagrams <= n_datagrams + 1;
                      n_bytes_out <= n_bytes_out + pending;

                      if pending mod PKT_BYTES /= 0 then
                        n_bad_len <= n_bad_len + 1;
                        report "DATAGRAM " & integer'image(n_datagrams)
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
                             /= pkt_byte(expect, b) then
                            rec_ok := false;
                          end if;
                        end loop;
                        if not rec_ok then
                          bad_rec := bad_rec + 1;
                          if n_bad_rec + bad_rec <= 5 then
                            report "DATAGRAM " & integer'image(n_datagrams)
                                 & " record " & integer'image(r)
                                 & ": expected packet " & integer'image(expect)
                                 & ", got "
                                 & hex(txbuf(sock * TXBUF_SIZE + ((sent_upto(sock) + r * PKT_BYTES + 0) mod TXBUF_SIZE)))
                                 & " " & hex(txbuf(sock * TXBUF_SIZE + ((sent_upto(sock) + r * PKT_BYTES + 1) mod TXBUF_SIZE)))
                                 & " " & hex(txbuf(sock * TXBUF_SIZE + ((sent_upto(sock) + r * PKT_BYTES + 2) mod TXBUF_SIZE)))
                                 & " " & hex(txbuf(sock * TXBUF_SIZE + ((sent_upto(sock) + r * PKT_BYTES + 3) mod TXBUF_SIZE)))
                                 & " " & hex(txbuf(sock * TXBUF_SIZE + ((sent_upto(sock) + r * PKT_BYTES + 4) mod TXBUF_SIZE)))
                                 & " " & hex(txbuf(sock * TXBUF_SIZE + ((sent_upto(sock) + r * PKT_BYTES + 5) mod TXBUF_SIZE)))
                                 & " " & hex(txbuf(sock * TXBUF_SIZE + ((sent_upto(sock) + r * PKT_BYTES + 6) mod TXBUF_SIZE)))
                                 & " " & hex(txbuf(sock * TXBUF_SIZE + ((sent_upto(sock) + r * PKT_BYTES + 7) mod TXBUF_SIZE)))
                                 & " " & hex(txbuf(sock * TXBUF_SIZE + ((sent_upto(sock) + r * PKT_BYTES + 8) mod TXBUF_SIZE)))
                              severity warning;
                          end if;
                        end if;
                        expect := expect + 1;
                      end loop;

                      n_records <= n_records + pending / PKT_BYTES;
                      n_bad_rec <= n_bad_rec + bad_rec;

                      report "datagram " & integer'image(n_datagrams)
                           & ": socket " & integer'image(sock)
                           & ", " & integer'image(pending) & " bytes"
                           & ", " & integer'image(pending / PKT_BYTES) & " records"
                           & ", " & integer'image(bad_rec) & " bad"
                        severity note;

                      sent_upto(sock) := tx_wr(sock);
                      sn_ir(sock) := sn_ir(sock) or x"10";     -- SEND_OK
                    end if;
                  when 16#0028# =>                             -- Sn_RX_RD
                    if off = 0 then
                      rx_rd(sock) := (rx_rd(sock) mod 256) + to_integer(unsigned(rxbyte)) * 256;
                    else
                      rx_rd(sock) := (rx_rd(sock) / 256) * 256 + to_integer(unsigned(rxbyte));
                    end if;
                  when 16#0002# =>                             -- Sn_IR: write 1 clears
                    sn_ir(sock) := sn_ir(sock) and not rxbyte;
                  when others => null;                         -- Sn_SR is read-only
                end case;
              end if;
            end if;
            off := off + 1;
        end case;

        bytecnt := bytecnt + 1;
      end loop;

      if bytecnt > 0 then
        n_spi <= n_spi + 1;
        if blk = 3 and not is_wr then
          n_rx_reads <= n_rx_reads + 1;
        end if;
      end if;

      if G_TRACE = 1 and bytecnt > 0 then
        report "spi: blk=" & integer'image(blk)
             & " sock=" & integer'image(sock)
             & " addr=" & integer'image(addr)
             & " wr=" & boolean'image(is_wr)
             & " payload=" & integer'image(bytecnt - 3)
          severity note;
      end if;
    end loop;
  end process;

  ---------------------------------------------------------------------------
  -- Metric source
  ---------------------------------------------------------------------------
  feed : process
  begin
    ext_pl_tvalid <= '0';
    ext_pl_tlast  <= '0';
    wait until reset = '0';
    -- let the chip-init pipeline run to completion before offering anything
    wait for 400 us;
    wait until rising_edge(clk);

    for i in 0 to G_PACKETS - 1 loop
      for b in 0 to PKT_BYTES - 1 loop
        ext_pl_tdata  <= pkt_byte(i, b);
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
    -- the chip-init pipeline is running from here on, so the bus should never
    -- go quiet for long again
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
  -- Receive-side checker: the chain must hand the fabric exactly the payload
  -- the chip held, split back into packets on tlast.
  ---------------------------------------------------------------------------
  rx_check : process
    constant RX_HDR : integer := 8;   -- W5500 prepends source IP, port, length
    variable idx    : integer := 0;   -- byte within the current packet
    variable expect : integer := 0;   -- packet number expected
    variable bad    : boolean := false;
  begin
    loop
      wait until rising_edge(clk);
      if ext_pl_rvalid = '1' and ext_pl_rready = '1' then
        if G_TRACE = 3 then
          report "rx byte " & integer'image(idx) & " = " & hex(ext_pl_rdata)
               & " last=" & std_logic'image(ext_pl_rlast) severity note;
        end if;
        if idx >= RX_HDR and idx < RX_HDR + PKT_BYTES
           and ext_pl_rdata /= pkt_byte(expect, idx - RX_HDR) then
          bad := true;
        end if;
        idx := idx + 1;
        if ext_pl_rlast = '1' then
          if idx /= RX_HDR + PKT_BYTES then
            bad := true;
          end if;
          if bad then
            n_rx_bad <= n_rx_bad + 1;
            report "RX packet " & integer'image(expect) & " wrong ("
                 & integer'image(idx) & " bytes)" severity warning;
          end if;
          n_rx_records <= n_rx_records + 1;
          expect := expect + 1;
          idx := 0;
          bad := false;
        end if;
      end if;
    end loop;
  end process;

  ---------------------------------------------------------------------------
  -- Report
  ---------------------------------------------------------------------------
  reporter : process
  begin
    wait until feed_done = '1';
    -- long enough for the idle-gap flush to fire and the last SEND to complete
    wait for 3 ms;

    report "=== tb_w5500_tx: batch=" & integer'image(G_BATCH)
         & " packets=" & integer'image(G_PACKETS)
         & " gap=" & integer'image(G_GAP) & " clks"
         & " stall=" & integer'image(G_STALL) & "@" & integer'image(G_STALL_AT)
         & " ===" severity note;
    report "fed        : " & integer'image(n_fed) & " packets, "
         & integer'image(n_fed * PKT_BYTES) & " bytes" severity note;
    report "transmitted: " & integer'image(n_datagrams) & " datagrams, "
         & integer'image(n_bytes_out) & " bytes, "
         & integer'image(n_records) & " records" severity note;
    report "bad lengths: " & integer'image(n_bad_len) severity note;
    report "bad records: " & integer'image(n_bad_rec) severity note;
    report "SEND dropped (chip still transmitting): "
         & integer'image(n_send_drop) severity note;
    report "spi txns   : " & integer'image(n_spi)
         & "   rx-buffer reads: " & integer'image(n_rx_reads)
         & "   longest quiet: " & integer'image(cs_idle_max) & " clks" severity note;
    report "rx staged  : " & integer'image(G_RX_PACKETS)
         & "   rx delivered: " & integer'image(n_rx_records)
         & "   rx bad: " & integer'image(n_rx_bad) severity note;

    -- The chip says there are bytes waiting, so the machine must come and read
    -- them. Reporting a full 2048-byte buffer as empty is exactly the wedge.
    assert not (G_RX_FILL > 0) or n_rx_reads > 0
      report "SOCKET SKIPPED: chip reported " & integer'image(G_RX_FILL)
           & " bytes waiting and the machine never read the buffer"
      severity error;

    -- A parked machine issues nothing at all. Everything here runs in
    -- microseconds, so anything approaching the watchdog threshold is a hang.
    assert cs_idle_max < 40000
      report "BUS WENT QUIET for " & integer'image(cs_idle_max)
           & " clocks -- the machine parked" severity error;

    -- G_RX_FILL stages a byte count rather than whole packets, so only the
    -- "did the machine come and read it" question applies there.
    assert G_RX_FILL > 0 or n_rx_records = G_RX_PACKETS
      report "RX PATH: delivered " & integer'image(n_rx_records) & " of "
           & integer'image(G_RX_PACKETS) & " staged packets" severity error;
    assert G_RX_FILL > 0 or n_rx_bad = 0
      report "RX PATH: " & integer'image(n_rx_bad) & " corrupted packets"
      severity error;
    report "bytes into TX buffer: " & integer'image(n_buf_writes)
         & "  (Sn_TX_WR advance: " & integer'image(n_bytes_out) & ")" severity note;

    assert n_buf_writes = n_fed * PKT_BYTES
      report "SPI OVER/UNDER-SHIFT: chip received " & integer'image(n_buf_writes)
           & " bytes for " & integer'image(n_fed * PKT_BYTES) & " fed"
      severity error;

    assert n_bytes_out = n_fed * PKT_BYTES
      report "BYTE COUNT MISMATCH: Sn_TX_WR advanced " & integer'image(n_bytes_out)
           & " bytes for " & integer'image(n_fed * PKT_BYTES) & " bytes written"
      severity error;
    assert n_bad_len = 0
      report "MALFORMED DATAGRAM LENGTHS: " & integer'image(n_bad_len) severity error;
    assert n_bad_rec = 0
      report "DISPLACED RECORDS: " & integer'image(n_bad_rec) severity error;
    assert n_send_drop = 0
      report "LOST SEND COMMANDS: " & integer'image(n_send_drop)
           & " -- the firmware issued SEND while the chip was still transmitting"
      severity error;

    if n_bytes_out = n_fed * PKT_BYTES and n_bad_len = 0 and n_bad_rec = 0
       and n_records = n_fed and n_buf_writes = n_fed * PKT_BYTES
       and (G_RX_FILL > 0 or (n_rx_records = G_RX_PACKETS and n_rx_bad = 0))
       and n_send_drop = 0 and cs_idle_max < 40000
       and (G_RX_FILL = 0 or n_rx_reads > 0) then
      report "PASS" severity note;
    else
      report "FAIL" severity note;
    end if;
    finish;
  end process;

end architecture;
