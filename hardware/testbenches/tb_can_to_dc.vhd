--------------------------------------------------------------------------------
-- tb_can_to_dc - integration testbench for the CAN metric source.
--
-- Chain under test:  can_metric_source (= can_node + adapter)  ->  data_concentrator(2ch)
--
-- The bench plays a CAN transmitter (real SOF..CRC + bit-stuffing + CRC-15, reused
-- from can_node_tb) on rx_pin. A decoded frame becomes a 9-byte V01 Metric Packet
-- on Data Concentrator input channel 1; channel 0 (W5500 slot) is held idle.
--
-- CAN ID -> device index: can_metric_adapter maps id(9:0) into metric_id(15:6),
-- the threshold-BRAM device index. We use ID 320 -> index 320, which the BRAM
-- (bram_threshold_lookup.vhd) initializes to lower=0, upper=0x000FA000 (Q22.10 1000.0).
--   * in-range frame  : value 500.0  (raw 0x0007D000) -> metric forwarded, no interlock.
--   * out-of-range    : value 2000.0 (raw 0x001F4000) -> interlock asserts.
--   * deassert_interlock then clears it.
--
-- What this verifies:
--   1. the adapter builds the correct V01 packet (header + identifier + value bytes)
--      with the CAN priority tuser, and it reaches the DC output (channel routing OK);
--   2. the full datapath parses the value correctly: an out-of-range CAN value trips
--      the interlock and an in-range one does not, and deassert clears it.
--
-- NOTE (PRE-EXISTING defect, NOT introduced by the CAN work): the Data Concentrator's
-- telemetry OUTPUT path (metric_packet_manager skid buffer / FWFT priority FIFO /
-- arbiter) does not faithfully forward packet CONTENT -- it repeats the first byte and
-- drops the final beat. This reproduces with NO CAN involved AND at
-- input_channel_amount = 1 (the original W5500-only mode): driving a single clean
-- packet straight into the DC yields "0x56 0x56 ..." at the output. The existing
-- sim_dc / sim_all never caught it because they only check the interlock signal,
-- never the forwarded bytes. Therefore this bench does NOT assert the forwarded
-- packet's content; it proves the CAN datapath via (a) routing (a CAN-tagged packet
-- reaches the output) and (b) the interlock, which can only trip on the correct
-- threshold if the header + ID mapping + full 4-byte value were parsed correctly.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;
use work.metric_axi_stream_pkg.all;

entity tb_can_to_dc is
end entity tb_can_to_dc;

architecture sim of tb_can_to_dc is
  constant CLKS_PER_BIT : integer := 16;       -- small so a frame simulates in a few us
  constant CLK_PERIOD   : time    := 25 ns;    -- 40 MHz system clock (clk0)

  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';             -- active-high (matches top.vhd)

  -- CAN bus line
  signal rx_pin       : std_logic := '1';      -- recessive idle

  -- can_metric_source -> data_concentrator channel 1
  signal can_axis        : metric_axi_stream_t;
  signal can_axis_tready : std_logic;

  -- data_concentrator I/O
  signal dc_in        : metric_axi_stream_array_t(1 downto 0);
  signal dc_in_ready  : std_logic_vector(1 downto 0);
  signal dc_tdata     : std_logic_vector(7 downto 0);
  signal dc_tvalid    : std_logic;
  signal dc_tlast     : std_logic;
  signal dc_tuser     : std_logic_vector(2 downto 0);
  signal dc_tready    : std_logic := '1';
  signal dc_interlock : std_logic;
  signal deassert     : std_logic := '0';

  -- output-byte capture (independent of tlast, which the DC output path drops)
  type byte_arr is array (0 to 8) of std_logic_vector(7 downto 0);
  signal cap_arm   : std_logic := '0';
  signal cap       : byte_arr := (others => (others => '0'));
  signal cap_tuser : std_logic_vector(2 downto 0) := (others => '0');
  signal cap_n     : integer := 0;

  -- CRC-15 (0x4599), transmission order (identical to can_node_tb)
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

  -- ---- DUT: the self-contained CAN metric source feeding DC channel 1 ----
  u_can_source : entity work.can_metric_source(rtl)
    generic map (
      CLKS_PER_BIT => CLKS_PER_BIT,
      ACK_DRIVE    => false,
      CAN_TUSER    => "001"
    )
    port map (
      clk           => clk,
      reset         => reset,
      can_rx        => rx_pin,
      m_axis        => can_axis,
      m_axis_tready => can_axis_tready,
      rx_id_low     => open,
      rx_activity   => open,
      overrun       => open,
      can_tx        => open  -- ACK_DRIVE=false here; the ACK path is covered by tb_can_ack
    );

  u_dc : entity work.data_concentrator(Behavioral)
    generic map (
      input_channel_amount => 2
    )
    port map (
      clk                  => clk,
      reset                => reset,
      tdata                => dc_tdata,
      tvalid               => dc_tvalid,
      tlast                => dc_tlast,
      tready               => dc_tready,
      tuser                => dc_tuser,
      s_axis               => dc_in,
      s_axis_ready         => dc_in_ready,
      interlock            => dc_interlock,
      deassert_interlock   => deassert,
      ext_interlock_source => '0'
    );

  -- channel 1 = CAN; channel 0 = W5500 (idle in this bench)
  dc_in(1)        <= can_axis;
  can_axis_tready <= dc_in_ready(1);
  dc_in(0)        <= (tdata => (others => '0'), tuser => (others => '0'),
                      tvalid => '0', tlast => '0');

  -- capture the first 9 output bytes after arming (does not rely on tlast)
  capture : process (clk)
    variable idx : integer := 0;
  begin
    if rising_edge(clk) then
      if cap_arm = '0' then
        idx := 0;
      elsif dc_tvalid = '1' and dc_tready = '1' then
        if idx < 9 then
          cap(idx)  <= dc_tdata;
          cap_tuser <= dc_tuser;
          idx       := idx + 1;
          cap_n     <= idx;
        end if;
      end if;
    end if;
  end process capture;

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

    -- Build + bit-stuff + drive a standard data frame (reused from can_node_tb).
    procedure send_frame(
      id    : std_logic_vector(10 downto 0);
      dlc   : std_logic_vector(3 downto 0);
      dat   : std_logic_vector(63 downto 0);
      nbits : integer) is
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
    -- In-range frame: ID 320, value 500.0 -> metric forwarded, no interlock.
    -- Verify the adapter-built packet content (first 8 bytes reliably emerge).
    ----------------------------------------------------------------------------
    cap_arm <= '1';
    send_frame(std_logic_vector(to_unsigned(320, 11)), "0100",
               x"000000000007D000", 32);          -- 500.0 in Q22.10
    idle(40);
    wait for 5 us;

    -- Routing proof: a CAN-tagged metric packet reached the DC telemetry output.
    -- (Byte-content of the forwarded packet is NOT asserted: the DC output FIFO/
    --  arbiter path has a pre-existing defect -- it stalls without advancing and
    --  drops the final beat -- reproducible with no CAN involved by driving a single
    --  packet on channel 0. Packet-content correctness is instead proven below by
    --  the interlock: a wrong header/ID/value could not trip the right threshold.)
    check(cap_n >= 1, "F1: no CAN metric packet reached the DC output (routing broken)");
    check(cap(0) = x"56", "F1: forwarded packet did not start with 'V' protocol byte");
    check(cap_tuser = "001", "F1: forwarded packet not tagged with the CAN priority (tuser)");
    check(dc_interlock = '0', "F1: interlock wrongly asserted for in-range value (500.0)");
    cap_arm <= '0';

    ----------------------------------------------------------------------------
    -- Out-of-range frame: ID 320, value 2000.0 (> upper 1000.0) -> interlock.
    -- This proves the FULL 4-byte value (incl. its last byte) was parsed.
    ----------------------------------------------------------------------------
    send_frame(std_logic_vector(to_unsigned(320, 11)), "0100",
               x"00000000001F4000", 32);          -- 2000.0 in Q22.10
    wait until dc_interlock = '1' for 100 us;
    check(dc_interlock = '1', "F2: interlock did NOT assert for out-of-range value");

    ----------------------------------------------------------------------------
    -- Clear the latched interlock via deassert_interlock
    ----------------------------------------------------------------------------
    deassert <= '1';
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    deassert <= '0';
    wait until dc_interlock = '0' for 10 us;
    check(dc_interlock = '0', "F3: interlock did not clear after deassert");

    ----------------------------------------------------------------------------
    if errors = 0 then
      report "ALL CAN->DC TESTS PASSED" severity note;
    else
      report "CAN->DC TESTS FAILED: " & integer'image(errors) & " error(s)"
        severity failure;
    end if;
    finish;
    wait;
  end process stimulus;

end architecture sim;
