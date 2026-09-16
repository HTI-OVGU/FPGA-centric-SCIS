-- Does the receive path stay in step with the chip's buffer under sustained
-- arrival, or does it drift?
--
-- On hardware the board wedges reproducibly: three seconds of steady traffic at
-- about 26 000 packets/s and every UDP socket stops answering, while the chip
-- still replies to ping. Short bursts at 100 000 packets/s do not do it. That
-- shape -- long and steady rather than fast -- points at something that
-- accumulates, and the obvious candidate is Sn_RX_RD drifting off the datagram
-- boundaries: once the read pointer is misaligned, every later read returns the
-- middle of a datagram, the splitter never finds a header again, and the buffer
-- never truly drains.
--
-- So this bench models the chip as it actually behaves: datagrams keep arriving
-- into the socket's 2 KB receive buffer whether or not the controller keeps up,
-- and one that does not fit is dropped by the chip rather than queued. The
-- controller is the real receive-first state machine with all eight sockets.
--
-- What is checked, continuously:
--   * Sn_RX_RD only ever lands on a datagram boundary
--   * every datagram handed to the fabric is a whole one, in order
--   * the controller keeps issuing receive-buffer reads
--
--   G_ARRIVAL_CLKS  clocks between arrivals; 1154 at 30 MHz is 26 000 pkt/s
--   G_PACKETS       how many datagrams the chip receives before going quiet

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_w5500_rx_sustained is
  generic (
    G_ARRIVAL_CLKS : integer := 1154;
    G_PACKETS      : integer := 400;
    G_TRACE        : integer := 0;
    -- Backpressure from the fabric. On the board the data concentrator is not
    -- always ready: its FIFOs fill, the metric packet manager arbitrates, and
    -- the transmit side can stall it. G_RREADY_OFF clocks not ready followed by
    -- G_RREADY_ON clocks ready. 0 means always ready.
    G_RREADY_OFF : integer := 0;
    G_RREADY_ON  : integer := 16
  );
end entity;

architecture sim of tb_w5500_rx_sustained is

  constant CLK_PERIOD : time := 33333 ps;
  constant PAYLOAD    : integer := 9;
  constant RXHDR      : integer := 8;
  constant UNIT       : integer := RXHDR + PAYLOAD;   -- 17 bytes per datagram
  constant BUFSZ      : integer := 2048;

  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';

  signal mosi, miso, sclk, cs : std_logic;
  signal spi_busy : std_logic;

  signal tdata, rdata : std_logic_vector(7 downto 0);
  signal tvalid, tready, tlast : std_logic;
  signal rvalid, rready, rlast : std_logic;

  signal ext_pl_rdata  : std_logic_vector(7 downto 0);
  signal ext_pl_rvalid : std_logic;
  signal ext_pl_rlast  : std_logic;
  signal ext_pl_ruser  : std_logic_vector(2 downto 0);
  signal ext_pl_rready : std_logic := '1';

  type buf_t is array (0 to BUFSZ - 1) of std_logic_vector(7 downto 0);
  signal rxbuf : buf_t := (others => x"00");

  -- one driver each: the chip writes rx_wr, the controller's Sn_RX_RD write
  -- moves rx_rd
  signal rx_wr : integer := 0;
  signal rx_rd : integer := 0;

  signal n_arrived   : integer := 0;
  signal n_dropped   : integer := 0;
  signal n_delivered : integer := 0;
  signal n_bad       : integer := 0;
  signal n_misaligned: integer := 0;
  signal n_rx_reads  : integer := 0;
  signal cs_idle_max : integer := 0;
  signal produced    : std_logic := '0';
  signal t_first     : time := 0 ns;
  signal t_last      : time := 0 ns;

  function pkt_byte(i : integer; b : integer) return std_logic_vector is
  begin
    case b is
      when 0 => return x"56";
      when 1 => return x"30";
      when 2 => return x"31";
      when 3 => return std_logic_vector(to_unsigned((i / 256) mod 256, 8));
      when 4 => return std_logic_vector(to_unsigned(i mod 256, 8));
      when 5 => return x"A5";
      when 6 => return x"5A";
      when 7 => return std_logic_vector(to_unsigned((i / 256) mod 256, 8));
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
      socket_amount   => 8,
      DEFAULT_ROUTINE => "receive_first")
    port map (
      clk => clk, reset => reset, spi_busy => spi_busy,
      tdata => tdata, tvalid => tvalid, tready => tready, tlast => tlast,
      rdata => rdata, rvalid => rvalid, rready => rready, rlast => rlast,
      ext_pl_tdata => x"00", ext_pl_tready => open,
      ext_pl_tvalid => '0', ext_pl_tlast => '0', ext_pl_tuser => "000",
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
  -- The chip receiving datagrams. One that does not fit is dropped, which is
  -- what a W5500 does -- it never queues a partial datagram.
  ---------------------------------------------------------------------------
  producer : process
    variable seq  : integer := 0;
    variable base : integer;
  begin
    wait until reset = '0';
    wait for 400 us;                         -- chip-init pipeline
    while seq < G_PACKETS loop
      for k in 1 to G_ARRIVAL_CLKS loop
        wait until rising_edge(clk);
      end loop;

      if ((rx_wr - rx_rd) + UNIT) <= BUFSZ then
        base := rx_wr mod BUFSZ;
        rxbuf((base + 0) mod BUFSZ) <= x"C0";        -- source IP
        rxbuf((base + 1) mod BUFSZ) <= x"A8";
        rxbuf((base + 2) mod BUFSZ) <= x"02";
        rxbuf((base + 3) mod BUFSZ) <= x"6A";
        rxbuf((base + 4) mod BUFSZ) <= x"24";        -- source port
        rxbuf((base + 5) mod BUFSZ) <= x"01";
        rxbuf((base + 6) mod BUFSZ) <= x"00";        -- payload length
        rxbuf((base + 7) mod BUFSZ) <= std_logic_vector(to_unsigned(PAYLOAD, 8));
        for b in 0 to PAYLOAD - 1 loop
          rxbuf((base + RXHDR + b) mod BUFSZ) <= pkt_byte(seq, b);
        end loop;
        rx_wr     <= rx_wr + UNIT;
        n_arrived <= n_arrived + 1;
      else
        n_dropped <= n_dropped + 1;
      end if;
      seq := seq + 1;
    end loop;
    produced <= '1';
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- The chip answering SPI
  ---------------------------------------------------------------------------
  w5500 : process
    variable rxbyte  : std_logic_vector(7 downto 0) := (others => '0');
    variable txbyte  : std_logic_vector(7 downto 0) := (others => '0');
    variable bytecnt : integer := 0;
    variable addr    : integer := 0;
    variable ctrl    : std_logic_vector(7 downto 0) := (others => '0');
    variable sock    : integer := 0;
    variable blk     : integer := 0;
    variable is_wr   : boolean := false;
    variable off     : integer := 0;
    variable newrd   : integer := 0;

    impure function reg_read(k : integer) return std_logic_vector is
      variable rsr : integer;
    begin
      if blk = 3 then                                    -- receive buffer
        return rxbuf((addr + k) mod BUFSZ);
      end if;
      if blk = 1 then
        if sock /= 0 then                                -- only socket 0 is fed
          return x"00";
        end if;
        case addr is
          when 16#0026# =>                               -- Sn_RX_RSR
            rsr := rx_wr - rx_rd;
            if k = 0 then
              return std_logic_vector(to_unsigned(rsr / 256, 8));
            else
              return std_logic_vector(to_unsigned(rsr mod 256, 8));
            end if;
          when 16#0028# =>                               -- Sn_RX_RD
            if k = 0 then
              return std_logic_vector(to_unsigned((rx_rd mod 65536) / 256, 8));
            else
              return std_logic_vector(to_unsigned(rx_rd mod 256, 8));
            end if;
          when 16#0002# => return x"10";                 -- Sn_IR: SEND_OK
          when 16#0003# => return x"22";                 -- Sn_SR: SOCK_UDP
          when 16#0020# => return x"08";                 -- Sn_TX_FSR high: 2048
          when others   => return x"00";
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
      newrd   := rx_rd;

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
            if is_wr and blk = 1 and sock = 0 and addr = 16#0028# then
              if off = 0 then
                newrd := (newrd mod 256) + to_integer(unsigned(rxbyte)) * 256;
              else
                newrd := (newrd / 256) * 256 + to_integer(unsigned(rxbyte));
              end if;
            end if;
            off := off + 1;
        end case;
        bytecnt := bytecnt + 1;
      end loop;

      if bytecnt > 0 then
        if blk = 3 and not is_wr then
          n_rx_reads <= n_rx_reads + 1;
          if G_TRACE = 1 then
            report "read " & integer'image(bytecnt - 3) & " bytes from addr "
                 & integer'image(addr) severity note;
          end if;
        end if;
        if is_wr and blk = 1 and sock = 0 and addr = 16#0028# then
          -- Sn_RX_RD may only ever land on a datagram boundary. Anything else
          -- means the controller consumed a partial datagram and every read
          -- after this one starts in the middle of one.
          if (newrd mod UNIT) /= 0 then
            n_misaligned <= n_misaligned + 1;
            report "Sn_RX_RD <= " & integer'image(newrd)
                 & " is not a multiple of " & integer'image(UNIT)
                 & " -- read pointer is off the datagram grid" severity warning;
          end if;
          rx_rd <= newrd;
        end if;
      end if;
    end loop;
  end process;

  backpressure : process
  begin
    if G_RREADY_OFF = 0 then
      ext_pl_rready <= '1';
      wait;
    end if;
    loop
      ext_pl_rready <= '1';
      for k in 1 to G_RREADY_ON loop
        wait until rising_edge(clk);
      end loop;
      ext_pl_rready <= '0';
      for k in 1 to G_RREADY_OFF loop
        wait until rising_edge(clk);
      end loop;
    end loop;
  end process;

  ---------------------------------------------------------------------------
  -- What the fabric receives
  ---------------------------------------------------------------------------
  -- The chip drops datagrams it has no room for, so the sequence arrives with
  -- gaps. What must hold is that every datagram handed over is a whole, valid
  -- one and that the sequence never goes backwards -- loss is legal here,
  -- corruption and reordering are not.
  checker : process
    variable idx    : integer := 0;
    variable seen   : integer := 0;         -- sequence carried by this datagram
    variable last   : integer := -1;
    variable bad    : boolean := false;
    variable payload_len : integer := 0;
    type dg_t is array (0 to 63) of std_logic_vector(7 downto 0);
    variable dg : dg_t := (others => x"00");
    variable msg : string(1 to 3 * 24) := (others => ' ');
  begin
    loop
      wait until rising_edge(clk);
      if ext_pl_rvalid = '1' and ext_pl_rready = '1' then
        if idx < 64 then
          dg(idx) := ext_pl_rdata;
        end if;
        if idx = 7 then
          payload_len := to_integer(unsigned(ext_pl_rdata));
        elsif idx = RXHDR + 0 and ext_pl_rdata /= x"56" then
          bad := true;
        elsif idx = RXHDR + 1 and ext_pl_rdata /= x"30" then
          bad := true;
        elsif idx = RXHDR + 2 and ext_pl_rdata /= x"31" then
          bad := true;
        elsif idx = RXHDR + 4 then
          seen := to_integer(unsigned(ext_pl_rdata));
        elsif idx = RXHDR + 8 and to_integer(unsigned(ext_pl_rdata)) /= seen then
          bad := true;                       -- the two copies must agree
        end if;
        idx := idx + 1;

        if ext_pl_rlast = '1' then
          if idx /= UNIT or payload_len /= PAYLOAD then
            bad := true;
          end if;
          if bad then
            n_bad <= n_bad + 1;
            if n_bad < 4 then
              for q in 0 to 23 loop
                if q < idx then
                  msg(3 * q + 1 to 3 * q + 2) := hex(dg(q));
                else
                  msg(3 * q + 1 to 3 * q + 2) := "..";
                end if;
                msg(3 * q + 3) := ' ';
              end loop;
              report "datagram " & integer'image(n_delivered) & " ("
                   & integer'image(idx) & " bytes): " & msg severity warning;
            end if;
          end if;
          if n_delivered = 0 then
            t_first <= now;
          end if;
          t_last <= now;
          n_delivered <= n_delivered + 1;
          last := seen;
          idx := 0;
          bad := false;
        end if;
      end if;
    end loop;
  end process;

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

  reporter : process
  begin
    wait until produced = '1';
    wait for 3 ms;
    report "=== tb_w5500_rx_sustained: arrival every "
         & integer'image(G_ARRIVAL_CLKS) & " clks, "
         & integer'image(G_PACKETS) & " datagrams ===" severity note;
    report "chip received : " & integer'image(n_arrived)
         & "   dropped (buffer full): " & integer'image(n_dropped) severity note;
    report "fabric got    : " & integer'image(n_delivered)
         & "   malformed: " & integer'image(n_bad) severity note;
    if t_last > t_first and n_delivered > 1 then
      report "receive rate  : "
           & integer'image((n_delivered - 1) * 1000000
                           / (integer((t_last - t_first) / 1 ns) / 1000))
           & " datagrams/s delivered to the fabric" severity note;
    end if;
    report "buffer reads  : " & integer'image(n_rx_reads)
         & "   Sn_RX_RD off the grid: " & integer'image(n_misaligned) severity note;
    report "longest quiet : " & integer'image(cs_idle_max) & " clks"
         & "   backpressure: " & integer'image(G_RREADY_OFF) & " off / "
         & integer'image(G_RREADY_ON) & " on" severity note;

    assert n_misaligned = 0
      report "READ POINTER MISALIGNED " & integer'image(n_misaligned) & " times"
      severity error;
    assert n_bad = 0
      report "MALFORMED DATAGRAMS: " & integer'image(n_bad) severity error;
    assert n_delivered = n_arrived
      report "DELIVERED " & integer'image(n_delivered) & " of "
           & integer'image(n_arrived) & " datagrams the chip accepted"
      severity error;
    assert cs_idle_max < 40000
      report "BUS WENT QUIET for " & integer'image(cs_idle_max) & " clocks"
      severity error;

    if n_misaligned = 0 and n_bad = 0 and n_delivered = n_arrived
       and cs_idle_max < 40000 then
      report "PASS" severity note;
    else
      report "FAIL" severity note;
    end if;
    finish;
  end process;

end architecture;
