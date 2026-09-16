-- Can the transmit controller livelock when the chip's transmit buffer stays
-- full, and does the watchdog catch it if it does?
--
-- CHECK_IF_FREE_SIZE_IS_AVAILABLE has no way out. When Sn_TX_FSR reports less
-- than minimum_free_tx_buffer_memory (256) it goes straight back to
-- GET_TX_FREE_BUFFER_SIZE (w5500_state_machine.vhd:816) and re-reads the *same*
-- socket. Nothing advances current_socket_counter, nothing falls through to the
-- receive branch, and there is no retry budget -- so the controller alternates
-- between two states for as long as the condition holds.
--
-- The watchdog cannot see it. p_watchdog (w5500_state_machine.vhd:390) zeroes
-- the counter whenever the state differs from the previous state:
--
--     if reset = '1' or w5500_control_flow_state /= prev_w5500_control_flow_state
--
-- A two-state alternation changes state on every SPI transaction, so the count
-- restarts continuously and WATCHDOG_CLKS is never reached. The watchdog is a
-- stuck-in-one-state detector, not a no-progress detector.
--
-- Why tb_w5500_tx never showed this: its behavioural chip frees the whole
-- buffer the instant SEND is written (`sent_upto(sock) := tx_wr(sock)`), so
-- Sn_TX_FSR is back to 2048 immediately and the low-free-space branch is
-- unreachable at any wire speed. Here the in-flight bytes keep occupying the
-- buffer until the wire has actually carried them, which is what the real chip
-- does -- Sn_TX_FSR is free space, and space is not free until it is sent.
--
-- The sweep is over how fast the chip drains:
--
--   G_TX_FIXED_NS   per-datagram wire time. 5000 ns is the honest 100 Mbit
--                   figure used by tb_w5500_tx; raising it models a link that
--                   cannot keep up (congested switch, lost link, half duplex)
--                   and is what drives the buffer full.
--   G_TXBUF         transmit buffer bytes per socket. The chip's default is
--                   2048; a smaller one reaches the same state sooner and is
--                   the cheap way to sweep the margin.
--   G_FEED_SOCKETS  how many sockets the fabric offers traffic on. With more
--                   than one, this also answers whether a stalled socket
--                   blocks the others -- the arbiter is upstream, but the
--                   controller is shared.
--
-- What is measured, all from the SPI pins so nothing depends on hierarchical
-- names:
--
--   fsr_streak_max  longest run of back-to-back Sn_TX_FSR reads with no other
--                   transaction in between. Two-state ping-pong shows up here
--                   and nowhere else: the bus stays busy, so cs_idle_max --
--                   the liveness measure tb_w5500_tx relies on -- stays small.
--   n_rsr_reads     Sn_RX_RSR reads. Zero after the stall begins means the
--                   receive branch is never reached while it lasts.
--   dg_per_socket   datagrams completed per socket, so a socket that never
--                   gets served is visible.
--
-- FAIL here means the livelock was reproduced, which is the point: this
-- testbench is the missing evidence, not a regression guard.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_w5500_tx_backpressure is
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
    G_WATCHDOG : integer := 65535;
    -- Sockets the controller opens, and sockets the fabric feeds. Feeding more
    -- than one is how "does a stalled socket block the others" gets answered.
    G_SOCKETS      : integer := 1;
    G_FEED_SOCKETS : integer := 1;
    -- Transmit buffer bytes per socket. 2048 is the chip default.
    G_TXBUF : integer := 2048;
    -- 1 = in-flight bytes still occupy the buffer until the wire has carried
    -- them (what the chip does). 0 = free the whole buffer on SEND, which is
    -- tb_w5500_tx's model and makes the stall unreachable -- kept so the two
    -- can be compared in one sweep.
    G_DRAIN : integer := 1;
    -- A run of this many consecutive Sn_TX_FSR reads is called a livelock.
    -- Legitimate polling reads it once per datagram, so anything above a
    -- handful is not polling.
    G_LIVELOCK_RUN : integer := 50;
    -- How long to let the feeder try before reporting, in us. A livelocked
    -- controller never raises feed_done, so the reporter needs its own bound.
    G_RUN_US : integer := 4000;
    -- Asymmetric load. With G_HOT_EVERY > 0 socket 0 gets every packet except
    -- one in G_HOT_EVERY, which goes to socket 1. That is the configuration the
    -- claim is about: one socket driven into backpressure while a *second*
    -- socket has traffic waiting. Round-robin feeding cannot show it, because
    -- spreading the load halves the pressure on each socket's own buffer and
    -- the stall never starts.
    G_HOT_EVERY : integer := 0
  );
end entity;

architecture sim of tb_w5500_tx_backpressure is

  constant CLK_PERIOD : time := 33333 ps;   -- 30 MHz, as on the board
  constant PKT_BYTES  : integer := 9;
  constant TXBUF_SIZE : integer := G_TXBUF;  -- per-socket transmit buffer

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

  -- Livelock instrumentation, all derived from the SPI transactions.
  signal n_fsr_reads    : integer := 0;   -- Sn_TX_FSR reads, total
  signal fsr_streak     : integer := 0;   -- consecutive, no other txn between
  signal fsr_streak_max : integer := 0;
  signal n_rsr_reads    : integer := 0;   -- Sn_RX_RSR reads, total
  signal rsr_at_stall   : integer := 0;   -- value of n_rsr_reads when the
                                          -- first livelock run was recognised
  signal stall_seen     : std_logic := '0';
  signal min_free_seen  : integer := 65536;
  signal streak_span_max : time := 0 ns;   -- wall-clock length of the longest run
  signal stall_start     : time := 0 ns;
  type   sockcnt_t is array (0 to 7) of integer;
  signal dg_per_socket  : sockcnt_t := (others => 0);

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
      socket_amount        => G_SOCKETS,
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

    type time_t is array (0 to 7) of time;

    variable txbuf     : buf_t := (others => x"00");
    variable tx_wr     : ptr_t := (others => 0);   -- Sn_TX_WR
    variable sent_upto : ptr_t := (others => 0);   -- what SEND has already taken
    -- Bytes the wire has actually carried. Sn_TX_FSR is *free* space, and space
    -- occupied by a datagram still going out is not free -- which is the whole
    -- difference between this model and tb_w5500_tx's.
    variable drained   : ptr_t  := (others => 0);
    variable tx_done   : time_t := (others => 0 ns);
    variable sn_ir     : reg_t := (others => x"00");

    variable rxbuf  : buf_t := (others => x"00");
    variable rx_wr  : ptr_t := (others => 0);      -- how much the chip has staged
    variable rx_rd  : ptr_t := (others => 0);      -- Sn_RX_RD
    variable staged : boolean := false;

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

    -- Livelock bookkeeping. Variables, not signals, so a value written during
    -- one transaction is readable in the next without a delta-cycle argument.
    variable v_streak     : integer := 0;
    variable v_streak_max : integer := 0;
    variable v_fsr        : integer := 0;
    variable v_rsr        : integer := 0;
    variable v_streak_t0  : time    := 0 ns;
    variable v_span_max   : time    := 0 ns;
    variable v_min_free   : integer := 65536;
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
            -- Retire anything the wire has finished with, then report what is
            -- genuinely free.
            if now >= tx_done(sock) then
              drained(sock) := sent_upto(sock);
            end if;
            if G_DRAIN = 1 then
              free_sz := TXBUF_SIZE - ((tx_wr(sock) - drained(sock)) mod 65536);
            else
              free_sz := TXBUF_SIZE - ((tx_wr(sock) - sent_upto(sock)) mod 65536);
            end if;
            if free_sz < 0 then
              free_sz := 0;                    -- the chip cannot report negative
            end if;
            if free_sz < v_min_free then
              v_min_free := free_sz;
            end if;
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
            if now >= tx_done(sock) then
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
                    if rxbyte = x"20" then                     -- SEND
                      -- Queued, not dropped: a SEND arriving while the wire is
                      -- still busy starts when the previous one finishes. That
                      -- keeps this testbench about the buffer filling up and
                      -- leaves the lost-SEND defect to tb_w5500_tx.
                      if now < tx_done(sock) then
                        n_send_drop <= n_send_drop + 1;
                      end if;
                      pending := (tx_wr(sock) - sent_upto(sock)) mod 65536;
                      if now > tx_done(sock) then
                        tx_done(sock) := now;
                      end if;
                      tx_done(sock) := tx_done(sock) + (G_TX_FIXED_NS * 1 ns)
                                                     + (pending * 80 ns);
                      dg_per_socket(sock) <= dg_per_socket(sock) + 1;
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

        -- Livelock detection, purely from the bus. A run of Sn_TX_FSR reads
        -- with nothing else in between is the GET_TX_FREE_BUFFER_SIZE <->
        -- CHECK_IF_FREE_SIZE_IS_AVAILABLE alternation and nothing else: the
        -- check state issues no transaction of its own, so a controller making
        -- progress always puts something else on the bus between two reads.
        if blk = 1 and not is_wr and addr = 16#0020# then
          v_fsr := v_fsr + 1;
          if v_streak = 0 then
            v_streak_t0 := now;
          end if;
          v_streak := v_streak + 1;
          if v_streak > v_streak_max then
            v_streak_max := v_streak;
          end if;
          if now - v_streak_t0 > v_span_max then
            v_span_max := now - v_streak_t0;
          end if;
          if v_streak = G_LIVELOCK_RUN then
            stall_seen   <= '1';
            stall_start  <= v_streak_t0;
            rsr_at_stall <= v_rsr;
            report "LIVELOCK: " & integer'image(v_streak)
                 & " consecutive Sn_TX_FSR reads on socket "
                 & integer'image(sock)
                 & ", free space " & integer'image(v_min_free)
                 & " B -- the controller is re-reading the same register with no"
                 & " other transaction in between" severity warning;
          end if;
        elsif blk = 1 and not is_wr and addr = 16#0026# then
          v_rsr    := v_rsr + 1;
          v_streak := 0;
        else
          v_streak := 0;
        end if;

        n_fsr_reads     <= v_fsr;
        n_rsr_reads     <= v_rsr;
        fsr_streak      <= v_streak;
        fsr_streak_max  <= v_streak_max;
        streak_span_max <= v_span_max;
        min_free_seen   <= v_min_free;
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
      -- tuser is the socket the packet belongs to. Held for the whole packet:
      -- the controller latches it when the first byte is accepted.
      if G_HOT_EVERY > 0 then
        if (i mod G_HOT_EVERY) = G_HOT_EVERY - 1 then
          ext_pl_tuser <= "001";                  -- the cold socket
        else
          ext_pl_tuser <= "000";                  -- the hot socket
        end if;
      else
        ext_pl_tuser <= std_logic_vector(to_unsigned(i mod G_FEED_SOCKETS, 3));
      end if;
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
  --
  -- Deliberately not gated on feed_done. When the controller livelocks it stops
  -- accepting from the fabric, so the feeder blocks forever and a reporter that
  -- waits for it would never run -- the run would end on --stop-time with no
  -- output at all, which is the least useful possible result.
  ---------------------------------------------------------------------------
  reporter : process
    constant WD_TIME : time := G_WATCHDOG * CLK_PERIOD;
    variable rsr_after : integer;
    variable livelock  : boolean;
    variable starved   : boolean;
  begin
    wait until feed_done = '1' for G_RUN_US * 1 us;
    wait for 3 ms;

    livelock  := fsr_streak_max >= G_LIVELOCK_RUN;
    -- Reads that happened after the stall *ended* are counted here too, so this
    -- is not the starvation measure. The streak itself is: any Sn_RX_RSR read
    -- resets it, so a run of N back-to-back Sn_TX_FSR reads is proof that the
    -- receive branch was not entered once across that whole span.
    rsr_after := n_rsr_reads - rsr_at_stall;
    starved   := livelock;

    report "=== tb_w5500_tx_backpressure:"
         & " batch=" & integer'image(G_BATCH)
         & " sockets=" & integer'image(G_SOCKETS)
         & " fed_sockets=" & integer'image(G_FEED_SOCKETS)
         & " txbuf=" & integer'image(G_TXBUF)
         & " wire=" & integer'image(G_TX_FIXED_NS) & "ns"
         & " drain=" & integer'image(G_DRAIN)
         & " ===" severity note;
    report "fed          : " & integer'image(n_fed) & " of "
         & integer'image(G_PACKETS) & " packets accepted by the controller"
      severity note;
    report "transmitted  : " & integer'image(n_datagrams) & " datagrams, "
         & integer'image(n_records) & " records" severity note;
    report "datagrams/sck: "
         & integer'image(dg_per_socket(0)) & " "
         & integer'image(dg_per_socket(1)) & " "
         & integer'image(dg_per_socket(2)) & " "
         & integer'image(dg_per_socket(3)) & " "
         & integer'image(dg_per_socket(4)) & " "
         & integer'image(dg_per_socket(5)) & " "
         & integer'image(dg_per_socket(6)) & " "
         & integer'image(dg_per_socket(7)) severity note;
    report "min free tx  : " & integer'image(min_free_seen)
         & " B (threshold is minimum_free_tx_buffer_memory = 256)" severity note;
    report "Sn_TX_FSR    : " & integer'image(n_fsr_reads) & " reads, longest run "
         & integer'image(fsr_streak_max) & " back-to-back, spanning "
         & time'image(streak_span_max) severity note;
    report "Sn_RX_RSR    : " & integer'image(n_rsr_reads)
         & " reads total (" & integer'image(rsr_after)
         & " after the first stall began, stall and recovery together)"
      severity note;
    report "spi txns     : " & integer'image(n_spi)
         & "   longest quiet bus: " & integer'image(cs_idle_max) & " clks"
         & "   (watchdog threshold " & integer'image(G_WATCHDOG)
         & " clks = " & time'image(WD_TIME) & ")" severity note;

    if livelock then
      report "LIVELOCK CONFIRMED: " & integer'image(fsr_streak_max)
           & " consecutive Sn_TX_FSR reads of one socket, no other transaction"
           & " in between. GET_TX_FREE_BUFFER_SIZE <->"
           & " CHECK_IF_FREE_SIZE_IS_AVAILABLE with no retry budget and no exit"
           & " to the receive branch." severity warning;

      -- The bus stays busy throughout, so the liveness measure the other
      -- testbenches rely on cannot see this at all.
      report "WATCHDOG: the run spanned " & time'image(streak_span_max)
           & " against a " & time'image(WD_TIME) & " threshold, and the bus was"
           & " never quiet for more than " & integer'image(cs_idle_max)
           & " clks. p_watchdog zeroes on every state change, so a two-state"
           & " alternation never reaches the threshold -- confirmed: the"
           & " controller did not recover on its own." severity warning;

      if G_HOT_EVERY > 0 then
        report "ASYMMETRIC: socket 0 got " & integer'image(dg_per_socket(0))
             & " datagrams out, socket 1 (one packet in "
             & integer'image(G_HOT_EVERY) & ") got "
             & integer'image(dg_per_socket(1))
             & " -- a socket that never gets a datagram out while another"
             & " socket's buffer is full is the blocking this tests for"
          severity note;
      end if;

      if starved then
        report "STARVATION: across the longest run the controller issued "
             & integer'image(fsr_streak_max)
             & " Sn_TX_FSR reads and nothing else, so Sn_RX_RSR was not read"
             & " once in " & time'image(streak_span_max)
             & " -- the receive branch, and every other socket, is unreachable"
             & " for as long as one socket's buffer stays full" severity warning;
      end if;
      report "RESULT=LIVELOCK" severity note;
    else
      report "RESULT=NO-LIVELOCK" severity note;
    end if;
    finish;
  end process;

end architecture;
