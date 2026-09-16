--------------------------------------------------------------------------------
-- tb_can_ack - focused testbench for the CAN node's ACK-slot transmit path.
--
-- Exercises can_metric_source with ACK_DRIVE=true -- the shipping configuration in
-- top.vhd. sim_can_dc runs ACK_DRIVE=false, so the dominant-ACK logic in can_node
-- (tx_pin drive) was previously never simulated. This bench closes that gap.
--
-- ECHO_RX and TX_OPEN_DRAIN are left at their defaults (both false), i.e. can_tx is a
-- fully-driven push-pull net -- wiring configs (A) and (C) in top.vhd. The board
-- currently ships config (B) (TX_OPEN_DRAIN=true), which changes only the recessive
-- level from a driven '1' to 'Z'; the ACK logic under test here is identical.
--
-- It drives real bit-stuffed standard CAN frames on can_rx and observes can_tx
-- (recessive-HIGH when idle):
--   * good-CRC frame -> node accepts it, drives a dominant ACK (can_tx = '0') and
--                       pulses rx_activity.
--   * bad-CRC frame  -> node rejects it, never drives the bus (can_tx stays '1') and
--                       rx_activity stays low.
--
-- The frame transmitter (SOF..CRC + bit-stuffing + CRC-15 0x4599) is the same one
-- used by tb_can_to_dc; send_frame here adds a bad_crc option that corrupts one CRC
-- bit to produce the rejected-frame case.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;
use work.metric_axi_stream_pkg.all;

entity tb_can_ack is
end entity tb_can_ack;

architecture sim of tb_can_ack is
  constant CLKS_PER_BIT : integer := 16;       -- small so a frame simulates in a few us
  constant CLK_PERIOD   : time    := 25 ns;    -- 40 MHz sim clock (value is arbitrary here)

  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';             -- active-high (matches top.vhd)

  signal rx_pin : std_logic := '1';            -- CAN bus as seen by the FPGA RX (recessive idle)
  signal can_tx : std_logic;                   -- FPGA -> transceiver TXD (recessive '1' idle)

  signal m_axis        : metric_axi_stream_t;
  signal m_axis_tready : std_logic := '1';
  signal rx_activity   : std_logic;

  -- ACK observation: latch any dominant drive on can_tx; ack_clr resets it between tests
  signal ack_seen : std_logic := '0';
  signal ack_clr  : std_logic := '0';

  -- CRC-15 (0x4599), transmission order (identical to can_node / tb_can_to_dc)
  function crc15(bits : std_logic_vector) return std_logic_vector is
    constant poly : std_logic_vector(14 downto 0) := "100010110011001";
    variable crc  : std_logic_vector(14 downto 0) := (others => '0');
    variable nxt  : std_logic;
  begin
    for i in bits'low to bits'high loop
      nxt := bits(i) xor crc(14);
      crc := crc(13 downto 0) & '0';
      if nxt = '1' then
        crc := crc xor poly;
      end if;
    end loop;
    return crc;
  end function;

begin

  clk <= not clk after CLK_PERIOD / 2;

  -- ---- DUT: the self-contained CAN metric source, ACK-driving (active node) ----
  dut : entity work.can_metric_source(rtl)
    generic map (
      CLKS_PER_BIT => CLKS_PER_BIT,
      ACK_DRIVE    => true,
      CAN_TUSER    => "001"
    )
    port map (
      clk           => clk,
      reset         => reset,
      can_rx        => rx_pin,
      m_axis        => m_axis,
      m_axis_tready => m_axis_tready,
      rx_id_low     => open,
      rx_activity   => rx_activity,
      overrun       => open,
      can_tx        => can_tx
    );

  -- Latch any dominant drive on can_tx (the ACK). ack_clr clears it between sub-tests.
  ack_monitor : process (clk)
  begin
    if rising_edge(clk) then
      if ack_clr = '1' then
        ack_seen <= '0';
      elsif can_tx = '0' then
        ack_seen <= '1';
      end if;
    end if;
  end process ack_monitor;

  stimulus : process
    variable errors : integer := 0;

    procedure send_bit(b : std_logic) is
    begin
      rx_pin <= b;
      for i in 1 to CLKS_PER_BIT loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

    procedure idle(bits : integer) is
    begin
      for i in 1 to bits loop
        send_bit('1');
      end loop;
    end procedure;

    -- Build + bit-stuff + drive a standard data frame. bad_crc corrupts one CRC bit.
    procedure send_frame(
      id      : std_logic_vector(10 downto 0);
      dlc     : std_logic_vector(3 downto 0);
      dat     : std_logic_vector(63 downto 0);
      nbits   : integer;
      bad_crc : boolean) is
      variable buf  : std_logic_vector(0 to 127);
      variable n    : integer := 0;
      variable crc  : std_logic_vector(14 downto 0);
      variable prev : std_logic;
      variable cnt  : integer;
      variable b    : std_logic;
    begin
      n := 0;
      buf(n) := '0'; n := n + 1;                 -- SOF
      for i in 10 downto 0 loop buf(n) := id(i); n := n + 1; end loop;
      buf(n) := '0'; n := n + 1;                 -- RTR (data frame)
      buf(n) := '0'; n := n + 1;                 -- IDE (standard)
      buf(n) := '0'; n := n + 1;                 -- r0
      for i in 3 downto 0 loop buf(n) := dlc(i); n := n + 1; end loop;
      for i in nbits - 1 downto 0 loop buf(n) := dat(i); n := n + 1; end loop;
      crc := crc15(buf(0 to n - 1));
      if bad_crc then
        crc(0) := not crc(0);                    -- flip one CRC bit -> node must reject
      end if;
      for i in 14 downto 0 loop buf(n) := crc(i); n := n + 1; end loop;

      prev := '1'; cnt := 1;
      for i in 0 to n - 1 loop
        b := buf(i);
        if b = prev then cnt := cnt + 1; else cnt := 1; end if;
        prev := b;
        send_bit(b);
        if cnt = 5 then
          send_bit(not b); prev := not b; cnt := 1;
        end if;
      end loop;
      idle(1 + 1 + 1 + 7 + 3);                    -- CRC delim, ACK, ACK delim, EOF, IFS
    end procedure;

    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then
        report msg severity error;
        errors := errors + 1;
      end if;
    end procedure;

  begin
    -- reset
    reset <= '1';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    reset <= '0';
    idle(8);

    ----------------------------------------------------------------------------
    -- Test 1: bad-CRC frame -> node must NOT accept it and must NOT drive the bus.
    ----------------------------------------------------------------------------
    ack_clr <= '1'; wait until rising_edge(clk); ack_clr <= '0';
    send_frame(std_logic_vector(to_unsigned(320, 11)), "0100",
               x"000000000007D000", 32, bad_crc => true);
    idle(20);
    check(ack_seen = '0', "F1: node drove a dominant ACK for a bad-CRC frame");
    check(rx_activity = '0', "F1: rx_activity asserted for a bad-CRC frame");

    ----------------------------------------------------------------------------
    -- Test 2: good-CRC frame -> node must ACK (can_tx dominant) and accept it.
    ----------------------------------------------------------------------------
    ack_clr <= '1'; wait until rising_edge(clk); ack_clr <= '0';
    send_frame(std_logic_vector(to_unsigned(320, 11)), "0100",
               x"000000000007D000", 32, bad_crc => false);
    idle(20);
    check(ack_seen = '1', "F2: node did NOT drive a dominant ACK for a good frame");
    check(rx_activity = '1', "F2: rx_activity did not assert for a good frame");

    ----------------------------------------------------------------------------
    if errors = 0 then
      report "ALL CAN ACK TESTS PASSED" severity note;
    else
      report "CAN ACK TESTS FAILED: " & integer'image(errors) & " error(s)"
        severity failure;
    end if;
    finish;
    wait;
  end process stimulus;

end architecture sim;
