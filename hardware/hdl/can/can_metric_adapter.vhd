-- can_metric_adapter
-- Converts one decoded CAN frame (from can_node) into a single 9-byte "V01"
-- Metric Packet on the standard metric_axi_stream_t, so a CAN bus can act as a
-- metric source feeding the Data Concentrator exactly like the W5500/UDP path.
--
-- Frame -> packet mapping (V01, 9 bytes): 'V''0''1' | id_hi id_lo | v3 v2 v1 v0
--   * Identifier: the 11-bit CAN ID is left-aligned into the 16-bit metric
--     identifier so it lands in metric_id(15 downto 6) -- the field threshold_logic
--     uses as the BRAM device index. Each CAN ID 0..1023 thus maps 1:1 to its own
--     threshold slot. (See the metric_id assignment to remap.)
--   * Value: a 4-byte Q22.10 value, MSB first. can_node shifts payload bits in
--     MSB-first and RIGHT-aligns them to DLC*8 bits, so for a frame whose payload
--     is exactly the 4-byte value (DLC=4) the value occupies the low 32 bits.
--     VALUE_LSBYTE_OFFSET selects which 4-byte window (counting from the LSB).
--
-- Buffering reuses the in-house metric_packet_fifo (as udp_packet_adapter does) so
-- downstream backpressure (latched interlock / FIFO-full) never corrupts a packet.
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.numeric_std.all;
use work.metric_axi_stream_pkg.all;

entity can_metric_adapter is
  generic (
    CAN_TUSER           : std_logic_vector(2 downto 0) := "001"; -- priority / FIFO slot for CAN metrics (distinct from W5500 sockets in use)
    VALUE_LSBYTE_OFFSET : natural                      := 0 -- 0 => value = rx_data(31:0); shift up by N bytes from the LSB
  );
  port (
    clk   : in std_logic;
    reset : in std_logic; -- active-HIGH synchronous reset (matches top.vhd)

    -- decoded CAN frame from can_node
    rx_id    : in std_logic_vector(10 downto 0);
    rx_dlc   : in std_logic_vector(3 downto 0); -- latched but unused by default mapping
    rx_data  : in std_logic_vector(63 downto 0);
    rx_valid : in std_logic; -- 1-clock good-frame strobe

    -- metric packet stream out (one Data Concentrator input channel)
    m_axis        : out metric_axi_stream_t;
    m_axis_tready : in std_logic;
    overrun       : out std_logic -- pulses if a new frame arrives while still draining one
  );
end can_metric_adapter;

architecture Behavioral of can_metric_adapter is

  component metric_packet_fifo is
    generic (
      g_WIDTH : natural := 20;
      g_DEPTH : natural := 1023
    );
    port (
      i_clk         : in std_logic;
      i_rst_sync    : in std_logic;
      s_axis_tvalid : in std_logic;
      s_axis_tdata  : in std_logic_vector(7 downto 0);
      s_axis_tlast  : in std_logic;
      s_axis_tready : out std_logic;
      s_axis_tuser  : in std_logic_vector(2 downto 0);
      m_axis_tvalid : out std_logic;
      m_axis_tdata  : out std_logic_vector(7 downto 0);
      m_axis_tlast  : out std_logic;
      m_axis_tready : in std_logic;
      m_axis_tuser  : out std_logic_vector(2 downto 0)
    );
  end component;

  type state_t is (IDLE, WRITE_PKT);
  signal state    : state_t              := IDLE;
  signal byte_idx : integer range 0 to 8 := 0;

  -- latched frame fields
  signal id_lat   : std_logic_vector(10 downto 0) := (others => '0');
  signal data_lat : std_logic_vector(63 downto 0) := (others => '0');

  -- derived metric fields
  signal metric_id : std_logic_vector(15 downto 0);
  signal value32   : std_logic_vector(31 downto 0);
  signal cur_byte  : std_logic_vector(7 downto 0);

  -- FIFO write side
  signal fifo_wr_tvalid : std_logic;
  signal fifo_wr_tdata  : std_logic_vector(7 downto 0);
  signal fifo_wr_tlast  : std_logic;
  signal fifo_wr_tready : std_logic;

begin

  -- CAN ID -> metric identifier (1:1 into the BRAM device-index field). Remap here.
  metric_id <= id_lat(9 downto 0) & "000000";

  -- 4-byte Q22.10 value window from the right-aligned payload (default: low 32 bits)
  value32 <= data_lat(31 + 8 * VALUE_LSBYTE_OFFSET downto 8 * VALUE_LSBYTE_OFFSET);

  -- byte serializer: 9-byte V01 packet, value MSB-first (matches threshold_logic assembly)
  with byte_idx select cur_byte <=
    x"56" when 0, -- 'V'
    x"30" when 1, -- '0'
    x"31" when 2, -- '1'
    metric_id(15 downto 8) when 3, -- identifier high
    metric_id(7 downto 0) when 4, -- identifier low
    value32(31 downto 24) when 5, -- value MSB
    value32(23 downto 16) when 6,
    value32(15 downto 8) when 7,
    value32(7 downto 0) when 8, -- value LSB
    x"00" when others;

  -- FIFO write-side drive (combinational from FSM state / byte index)
  fifo_wr_tvalid <= '1' when state = WRITE_PKT else
    '0';
  fifo_wr_tdata <= cur_byte;
  fifo_wr_tlast <= '1' when (state = WRITE_PKT and byte_idx = 8) else
    '0';

  packet_buffer_fifo : metric_packet_fifo
  generic map(
    g_WIDTH => 20,
    g_DEPTH => 1023
  )
  port map
  (
    i_clk         => clk,
    i_rst_sync    => reset,
    s_axis_tvalid => fifo_wr_tvalid,
    s_axis_tdata  => fifo_wr_tdata,
    s_axis_tlast  => fifo_wr_tlast,
    s_axis_tready => fifo_wr_tready,
    s_axis_tuser  => CAN_TUSER,
    m_axis_tvalid => m_axis.tvalid,
    m_axis_tdata  => m_axis.tdata,
    m_axis_tlast  => m_axis.tlast,
    m_axis_tready => m_axis_tready,
    m_axis_tuser  => m_axis.tuser
  );

  -- On rx_valid latch the frame, then push the 9 bytes into the FIFO one per
  -- accepted cycle. CAN is slow (>500 us/frame @125 kbps) vs the ~9-cycle drain,
  -- so overrun only happens under sustained downstream backpressure.
  process (clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        state    <= IDLE;
        byte_idx <= 0;
        id_lat   <= (others => '0');
        data_lat <= (others => '0');
        overrun  <= '0';
      else
        overrun <= '0'; -- default: single-cycle pulse
        case state is
          when IDLE =>
            if rx_valid = '1' then
              id_lat   <= rx_id;
              data_lat <= rx_data;
              byte_idx <= 0;
              state    <= WRITE_PKT;
            end if;

          when WRITE_PKT =>
            if rx_valid = '1' then
              overrun <= '1'; -- a new frame arrived mid-drain -> it is lost
            end if;
            if fifo_wr_tready = '1' then -- FIFO accepted the current byte
              if byte_idx = 8 then
                state    <= IDLE;
                byte_idx <= 0;
              else
                byte_idx <= byte_idx + 1;
              end if;
            end if;
        end case;
      end if;
    end if;
  end process;

end Behavioral;
