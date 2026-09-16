-- can_metric_source
-- Self-contained CAN metric source = the thesis "peripheral controller + adapter" unit.
-- Wraps the CAN receiver core (can_node) and the V01 packet adapter (can_metric_adapter)
-- so the top level instantiates ONE block: drive the bus pin in, get a Metric Packet
-- AXI-Stream out (ready to connect to one Data Concentrator input channel), plus two small
-- status outputs for the LED display. All CAN-internal wiring (rx_id/dlc/data/valid, the
-- activity pulse-stretch, the last-ID latch) is hidden inside here.
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.numeric_std.all;
use work.metric_axi_stream_pkg.all;

entity can_metric_source is
  generic (
    ClockFrequencyHz    : integer                      := 30_000_000; -- system (clk) rate (both boards drive 30 MHz clk0); with CLKS_PER_BIT=0 -> 125 kbps (CPB=240)
    CLKS_PER_BIT        : integer                      := 0; -- 0 = derive 125 kbps; else clk/bitrate
    ACK_DRIVE           : boolean                      := false; -- passive tap: never drive the bus
    ECHO_RX             : boolean                      := false; -- true only on a transceiver-less 2-wire link (see can_node header)
    TX_OPEN_DRAIN       : boolean                      := false; -- true only when can_tx sits directly on a pulled-up shared bus wire
    CAN_TUSER           : std_logic_vector(2 downto 0) := "001"; -- DC priority/FIFO slot for CAN
    VALUE_LSBYTE_OFFSET : natural                      := 0; -- which 4-byte window of the payload is the value
    RX_STRETCH_CLKS     : natural                      := 4_000_000 -- rx-activity LED stretch (~0.13 s @ 30 MHz)
  );
  port (
    clk   : in std_logic;
    reset : in std_logic; -- active-HIGH synchronous reset

    can_rx : in std_logic; -- CAN bus RX pin (logic level; sync'd in core)

    -- Metric Packet stream out -> one Data Concentrator input channel
    m_axis        : out metric_axi_stream_t;
    m_axis_tready : in std_logic;

    -- status for the LED display (purely informational)
    rx_id_low   : out std_logic_vector(2 downto 0); -- low 3 bits of the last accepted CAN ID
    rx_activity : out std_logic; -- pulse-stretched "frame received"
    overrun     : out std_logic; -- a frame arrived while the adapter was busy

    -- CAN TX pin -> transceiver TXD, or straight onto the bus wire on a
    -- transceiver-less link. Dominant LOW in the ACK slot of accepted frames when
    -- ACK_DRIVE=true, and mirroring can_rx the rest of the time when ECHO_RX=true.
    -- Recessive is a driven HIGH, or high-Z when TX_OPEN_DRAIN=true.
    can_tx : out std_logic
  );
end entity can_metric_source;

architecture rtl of can_metric_source is

  -- decoded-frame wires between the core and the adapter (private to this wrapper)
  signal can_id    : std_logic_vector(10 downto 0);
  signal can_dlc   : std_logic_vector(3 downto 0);
  signal can_data  : std_logic_vector(63 downto 0);
  signal can_valid : std_logic;

  -- LED status registers
  signal id_low_reg : std_logic_vector(2 downto 0)       := (others => '0');
  signal act_reg    : std_logic                          := '0';
  signal stretch    : integer range 0 to RX_STRETCH_CLKS := 0;

  -- core TX out, fully driven: '0' dominant, '1' recessive
  signal tx_pin_i : std_logic;

begin

  -- CAN receiver core (receive + ACK; it never originates a frame of its own).
  -- Core reset is active-low; top reset is active-high.
  u_core : entity work.can_node(rtl)
    generic map(
      ClockFrequencyHz => ClockFrequencyHz,
      CLKS_PER_BIT     => CLKS_PER_BIT,
      ACK_DRIVE        => ACK_DRIVE,
      ECHO_RX          => ECHO_RX,
      TX_OPEN_DRAIN    => TX_OPEN_DRAIN
    )
    port map
    (
      clk      => clk,
      nRst     => not reset,
      tx_pin   => tx_pin_i,
      rx_pin   => can_rx,
      rx_id    => can_id,
      rx_dlc   => can_dlc,
      rx_data  => can_data,
      rx_valid => can_valid
    );

  -- CAN frame -> 9-byte V01 Metric Packet on the standard metric AXI-Stream
  u_adapter : entity work.can_metric_adapter(Behavioral)
    generic map(
      CAN_TUSER           => CAN_TUSER,
      VALUE_LSBYTE_OFFSET => VALUE_LSBYTE_OFFSET
    )
    port map
    (
      clk           => clk,
      reset         => reset,
      rx_id         => can_id,
      rx_dlc        => can_dlc,
      rx_data       => can_data,
      rx_valid      => can_valid,
      m_axis        => m_axis,
      m_axis_tready => m_axis_tready,
      overrun       => overrun
    );

  -- LED status: latch the last ID's low bits, and pulse-stretch rx_valid (one clock = invisible)
  status : process (clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        id_low_reg <= (others => '0');
        act_reg    <= '0';
        stretch    <= 0;
      elsif can_valid = '1' then
        id_low_reg <= can_id(2 downto 0);
        act_reg    <= '1';
        stretch    <= RX_STRETCH_CLKS;
      elsif stretch > 0 then
        stretch <= stretch - 1;
        act_reg <= '1';
      else
        act_reg <= '0';
      end if;
    end if;
  end process status;

  rx_id_low   <= id_low_reg;
  rx_activity <= act_reg;

  -- Straight through: the core already drives tx_pin_i in the style TX_OPEN_DRAIN
  -- selects -- a fully-driven 2-state net when false (plain output buffer), or
  -- '0'/'Z' when true (tri-state buffer, CC_TOBUF on GateMate). Do NOT reintroduce
  -- a "'0' when tx_pin_i = '0' else '1'" remap here -- it would both defeat
  -- TX_OPEN_DRAIN and flatten the ECHO_RX mirror into a constant recessive.
  can_tx <= tx_pin_i;

end architecture rtl;
