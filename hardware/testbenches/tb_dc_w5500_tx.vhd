-- The whole transmit chain with the real source in front of it.
--
-- tb_w5500_tx drives the W5500 state machine from a hand-written stimulus and
-- passes at every batch depth. On hardware the same bitstream corrupts
-- datagrams as soon as packets accumulate, so the stimulus is not what the
-- fabric actually does. Here the data concentrator itself is the source --
-- priority FIFO, threshold logic, metric packet manager, telemetry sender --
-- feeding w5500_state_machine, spi_master and a behavioural W5500 that
-- publishes each datagram on SEND.
--
-- Checks are the ones the host-side acceptance test makes, so a failure here
-- and a failure on the board are the same measurement:
--   * every datagram length is a multiple of 9
--   * every 9-byte record starts with 'V01'
--   * every metric written comes back exactly once
--
--   G_BATCH  TX_BATCH_MAX_PACKETS
--   G_N      metrics fed into channel 0
--   G_GAP    idle clocks between metrics (sets the offered rate)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.metric_axi_stream_pkg.all;

entity tb_dc_w5500_tx is
  generic (
    G_BATCH : integer := 16;
    G_N     : integer := 60;
    G_GAP   : integer := 30;
    G_TRACE : integer := 0
  );
end entity;

architecture sim of tb_dc_w5500_tx is

  constant CLK_PERIOD : time := 33333 ps;   -- 30 MHz, as on the board
  constant PKT_BYTES  : integer := 9;
  constant TXBUF_SIZE : integer := 2048;
  constant VAL_BASE   : integer := 16#0007D000#;   -- 500.0 in Q22.10, in range

  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';

  signal mosi, miso, sclk, cs : std_logic;
  signal spi_busy : std_logic;

  signal tdata, rdata : std_logic_vector(7 downto 0);
  signal tvalid, tready, tlast : std_logic;
  signal rvalid, rready, rlast : std_logic;

  -- data concentrator -> state machine
  signal dc_tdata  : std_logic_vector(7 downto 0);
  signal dc_tvalid : std_logic;
  signal dc_tlast  : std_logic;
  signal dc_tready : std_logic;
  signal dc_tuser  : std_logic_vector(2 downto 0);

  signal dc_in       : metric_axi_stream_array_t(1 downto 0);
  signal dc_in_ready : std_logic_vector(1 downto 0);
  signal dc_interlock : std_logic;

  signal ext_pl_rdata  : std_logic_vector(7 downto 0);
  signal ext_pl_rvalid : std_logic;
  signal ext_pl_rlast  : std_logic;
  signal ext_pl_ruser  : std_logic_vector(2 downto 0);

  signal n_datagrams : integer := 0;
  signal n_bytes_out : integer := 0;
  signal n_records   : integer := 0;
  signal n_bad_len   : integer := 0;
  signal n_bad_rec   : integer := 0;
  signal n_seen      : integer := 0;
  signal n_dupe      : integer := 0;
  signal n_other     : integer := 0;
  signal n_fed       : integer := 0;
  signal feed_done   : std_logic := '0';
  -- when the first and the last datagram went out, so the sustained transmit
  -- rate can be reported rather than inferred
  signal t_first     : time := 0 ns;
  signal t_last      : time := 0 ns;

  function hex(v : std_logic_vector(7 downto 0)) return string is
    constant D : string := "0123456789ABCDEF";
    variable u : integer := to_integer(unsigned(v));
  begin
    return D(u / 16 + 1) & D(u mod 16 + 1);
  end function;

  -- metric i: identifier keeps device index 320 so the threshold entry is the
  -- same for every packet (lower 0, upper 1000.0), and the value carries the
  -- sequence number while staying comfortably in range.
  function pkt_byte(i : integer; b : integer) return std_logic_vector is
    variable ident : integer := 16#5000# + (i mod 64);
    variable val   : integer := VAL_BASE + i;
  begin
    case b is
      when 0 => return x"56";
      when 1 => return x"30";
      when 2 => return x"31";
      when 3 => return std_logic_vector(to_unsigned(ident / 256, 8));
      when 4 => return std_logic_vector(to_unsigned(ident mod 256, 8));
      when 5 => return std_logic_vector(to_unsigned((val / 16#1000000#) mod 256, 8));
      when 6 => return std_logic_vector(to_unsigned((val / 16#10000#) mod 256, 8));
      when 7 => return std_logic_vector(to_unsigned((val / 16#100#) mod 256, 8));
      when others => return std_logic_vector(to_unsigned(val mod 256, 8));
    end case;
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

  -- channel 1 is the CAN slot, held idle
  dc_in(1) <= (tdata => (others => '0'), tuser => (others => '0'),
               tvalid => '0', tlast => '0');

  u_dc : entity work.data_concentrator(Behavioral)
    generic map (input_channel_amount => 2)
    port map (
      clk => clk, reset => reset,
      tdata => dc_tdata, tvalid => dc_tvalid, tlast => dc_tlast,
      tready => dc_tready, tuser => dc_tuser,
      s_axis => dc_in, s_axis_ready => dc_in_ready,
      interlock => dc_interlock, deassert_interlock => '0',
      ext_interlock_source => '0');

  dut_fsm : entity work.w5500_state_machine
    generic map (
      socket_amount        => 8,
      DEFAULT_ROUTINE      => "send_first",
      TX_BATCH_MAX_PACKETS => G_BATCH)
    port map (
      clk => clk, reset => reset, spi_busy => spi_busy,
      tdata => tdata, tvalid => tvalid, tready => tready, tlast => tlast,
      rdata => rdata, rvalid => rvalid, rready => rready, rlast => rlast,
      ext_pl_tdata => dc_tdata, ext_pl_tready => dc_tready,
      ext_pl_tvalid => dc_tvalid, ext_pl_tlast => dc_tlast,
      ext_pl_tuser => dc_tuser,
      ext_pl_rdata => ext_pl_rdata, ext_pl_rready => '1',
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
    type buf_t is array (0 to 8 * TXBUF_SIZE - 1) of std_logic_vector(7 downto 0);
    type ptr_t is array (0 to 7) of integer;
    type reg_t is array (0 to 7) of std_logic_vector(7 downto 0);
    type seen_t is array (0 to 4095) of boolean;

    variable txbuf     : buf_t := (others => x"00");
    variable tx_wr     : ptr_t := (others => 0);
    variable sent_upto : ptr_t := (others => 0);
    variable sn_ir     : reg_t := (others => x"00");
    variable seen      : seen_t := (others => false);

    variable rxbyte  : std_logic_vector(7 downto 0) := (others => '0');
    variable txbyte  : std_logic_vector(7 downto 0) := (others => '0');
    variable bytecnt : integer := 0;
    variable addr    : integer := 0;
    variable ctrl    : std_logic_vector(7 downto 0) := (others => '0');
    variable sock    : integer := 0;
    variable blk     : integer := 0;
    variable is_wr   : boolean := false;
    variable off     : integer := 0;

    variable pending : integer := 0;
    variable bad_rec : integer := 0;
    variable base    : integer := 0;
    variable val     : integer := 0;
    variable seq     : integer := 0;
    -- accumulated inside the record loop, assigned once: a signal assignment
    -- repeated in a loop only takes effect once, so counting straight into the
    -- signals silently under-reports
    variable a_seen  : integer := 0;
    variable a_dupe  : integer := 0;
    variable a_other : integer := 0;

    impure function reg_read(k : integer) return std_logic_vector is
      variable free_sz : integer;
    begin
      if blk = 1 then
        case addr is
          when 16#0020# =>
            free_sz := TXBUF_SIZE - ((tx_wr(sock) - sent_upto(sock)) mod 65536);
            if k = 0 then
              return std_logic_vector(to_unsigned(free_sz / 256, 8));
            else
              return std_logic_vector(to_unsigned(free_sz mod 256, 8));
            end if;
          when 16#0024# =>
            if k = 0 then
              return std_logic_vector(to_unsigned(tx_wr(sock) / 256, 8));
            else
              return std_logic_vector(to_unsigned(tx_wr(sock) mod 256, 8));
            end if;
          when 16#0002# => return sn_ir(sock) or x"10";      -- SEND_OK
          when 16#0003# => return x"22";                     -- Sn_SR = SOCK_UDP
          when others   => return x"00";                     -- no receive traffic
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
              if blk = 2 then
                txbuf(sock * TXBUF_SIZE + ((addr + off) mod TXBUF_SIZE)) := rxbyte;
              elsif blk = 1 then
                case addr is
                  when 16#0024# =>
                    if off = 0 then
                      tx_wr(sock) := (tx_wr(sock) mod 256) + to_integer(unsigned(rxbyte)) * 256;
                    else
                      tx_wr(sock) := (tx_wr(sock) / 256) * 256 + to_integer(unsigned(rxbyte));
                    end if;
                  when 16#0001# =>
                    if rxbyte = x"20" then                     -- SEND
                      pending := (tx_wr(sock) - sent_upto(sock)) mod 65536;
                      n_datagrams <= n_datagrams + 1;
                      n_bytes_out <= n_bytes_out + pending;
                      if n_datagrams = 0 then
                        t_first <= now;
                      end if;
                      t_last <= now;

                      if pending mod PKT_BYTES /= 0 then
                        n_bad_len <= n_bad_len + 1;
                      end if;

                      bad_rec := 0;
                      a_seen  := 0;
                      a_dupe  := 0;
                      a_other := 0;
                      for r in 0 to pending / PKT_BYTES - 1 loop
                        base := sock * TXBUF_SIZE
                              + ((sent_upto(sock) + r * PKT_BYTES) mod TXBUF_SIZE);
                        if txbuf(base) /= x"56" or txbuf(base + 1) /= x"30"
                           or txbuf(base + 2) /= x"31" then
                          bad_rec := bad_rec + 1;
                          if n_bad_rec + bad_rec <= 4 then
                            report "datagram " & integer'image(n_datagrams)
                                 & " record " & integer'image(r) & ": "
                                 & hex(txbuf(base + 0)) & " " & hex(txbuf(base + 1))
                                 & " " & hex(txbuf(base + 2)) & " " & hex(txbuf(base + 3))
                                 & " " & hex(txbuf(base + 4)) & " " & hex(txbuf(base + 5))
                                 & " " & hex(txbuf(base + 6)) & " " & hex(txbuf(base + 7))
                                 & " " & hex(txbuf(base + 8)) severity warning;
                          end if;
                        else
                          val := to_integer(unsigned(txbuf(base + 5))) * 16#1000000#
                               + to_integer(unsigned(txbuf(base + 6))) * 16#10000#
                               + to_integer(unsigned(txbuf(base + 7))) * 16#100#
                               + to_integer(unsigned(txbuf(base + 8)));
                          seq := val - VAL_BASE;
                          if seq >= 0 and seq < 4096 then
                            if seen(seq) then
                              a_dupe := a_dupe + 1;
                            else
                              seen(seq) := true;
                              a_seen := a_seen + 1;
                            end if;
                          else
                            a_other := a_other + 1;   -- telemetry and the like
                          end if;
                        end if;
                      end loop;

                      n_records <= n_records + pending / PKT_BYTES;
                      n_bad_rec <= n_bad_rec + bad_rec;
                      n_seen    <= n_seen + a_seen;
                      n_dupe    <= n_dupe + a_dupe;
                      n_other   <= n_other + a_other;

                      if G_TRACE = 1 then
                        report "datagram " & integer'image(n_datagrams)
                             & ": socket " & integer'image(sock)
                             & ", " & integer'image(pending) & " bytes, "
                             & integer'image(bad_rec) & " bad" severity note;
                      end if;

                      sent_upto(sock) := tx_wr(sock);
                      sn_ir(sock) := sn_ir(sock) or x"10";
                    end if;
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
  -- Metric source into channel 0
  ---------------------------------------------------------------------------
  feed : process
  begin
    dc_in(0) <= (tdata => (others => '0'), tuser => "000",
                 tvalid => '0', tlast => '0');
    wait until reset = '0';
    wait for 400 us;                    -- chip-init pipeline
    wait until rising_edge(clk);

    for i in 0 to G_N - 1 loop
      for b in 0 to PKT_BYTES - 1 loop
        dc_in(0).tdata  <= pkt_byte(i, b);
        dc_in(0).tuser  <= "000";
        dc_in(0).tvalid <= '1';
        if b = PKT_BYTES - 1 then
          dc_in(0).tlast <= '1';
        else
          dc_in(0).tlast <= '0';
        end if;
        loop
          wait until rising_edge(clk);
          exit when dc_in_ready(0) = '1';
        end loop;
      end loop;
      dc_in(0).tvalid <= '0';
      dc_in(0).tlast  <= '0';
      n_fed <= i + 1;

      for g in 1 to G_GAP loop
        wait until rising_edge(clk);
      end loop;
    end loop;

    dc_in(0).tvalid <= '0';
    dc_in(0).tlast  <= '0';
    feed_done <= '1';
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- Report
  ---------------------------------------------------------------------------
  reporter : process
  begin
    wait until feed_done = '1';
    wait for 4 ms;

    report "=== tb_dc_w5500_tx: batch=" & integer'image(G_BATCH)
         & " metrics=" & integer'image(G_N)
         & " gap=" & integer'image(G_GAP) & " clks ===" severity note;
    report "fed         : " & integer'image(n_fed) severity note;
    report "datagrams   : " & integer'image(n_datagrams)
         & "   bytes: " & integer'image(n_bytes_out)
         & "   records: " & integer'image(n_records) severity note;
    if t_last > t_first and n_records > 1 then
      report "transmit rate: "
           & integer'image((n_records - 1) * 1000000
                           / (integer((t_last - t_first) / 1 ns) / 1000))
           & " metrics/s sustained" severity note;
    end if;
    report "bad lengths : " & integer'image(n_bad_len) severity note;
    report "bad records : " & integer'image(n_bad_rec) severity note;
    report "unique back : " & integer'image(n_seen)
         & "   dupes: " & integer'image(n_dupe)
         & "   other (telemetry): " & integer'image(n_other) severity note;

    assert n_bad_len = 0
      report "MALFORMED DATAGRAM LENGTHS: " & integer'image(n_bad_len) severity error;
    assert n_bad_rec = 0
      report "DISPLACED RECORDS: " & integer'image(n_bad_rec) severity error;
    assert n_seen = n_fed
      report "METRICS LOST: " & integer'image(n_seen) & " of "
           & integer'image(n_fed) severity error;

    if n_bad_len = 0 and n_bad_rec = 0 and n_seen = n_fed then
      report "PASS" severity note;
    else
      report "FAIL" severity note;
    end if;
    finish;
  end process;

end architecture;
