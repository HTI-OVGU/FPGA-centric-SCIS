--------------------------------------------------------------------------------
-- Project    : can_node
-- File       : can_node.vhd
-- VENDORED   : copied from ~/Documents/can_node/src/can_node.vhd. Edit the upstream
--              repo and re-copy here; do not let this vendored copy diverge.
-- Description : Reusable CAN-node core (RX path). CAN_RX walks an incoming frame
--              field-by-field (SOF, identifier, control, data, CRC, ACK, EOF),
--              sampling the RX line near the middle of each bit and
--              resynchronizing on recessive-to-dominant edges (bounded by SJW)
--              so the sample point can't drift over a frame. Active-low
--              synchronous reset. CLKS_PER_BIT sizes one CAN bit in clk cycles.
--              Bit de-stuffing and CRC-15 checking are done; crc_ok flags a
--              good frame. When ACK_DRIVE is true the node acknowledges accepted
--              frames by driving the ACK slot dominant on tx_pin; set ACK_DRIVE
--              false for receive-only links where the FPGA must never drive the
--              bus (tx_pin then stays recessive always).
--
--              tx_pin is always fully driven ('0' dominant / '1' recessive) --
--              never high-Z. A high-Z recessive leaves the far end's RX input
--              floating unless something pulls it up, which is a wiring trap;
--              build a real open-drain bus with ECHO_RX + an external pull-up
--              instead if that is what you want.
--
--              ECHO_RX exists for the transceiver-less link where the remote
--              CAN controller's TX and RX are two separate wires (its TX -> our
--              rx_pin, our tx_pin -> its RX). A transmitting CAN controller
--              bit-monitors: it compares every bit it sends against the level
--              it samples on its own RX, and flags a bit error on a mismatch.
--              With two independent wires it would never see its own dominant
--              bits come back and would error out on the SOF of every frame,
--              so with ECHO_RX true tx_pin mirrors rx_pin (plus the dominant
--              ACK), emulating the wired-AND bus the controller expects.
--              ECHO_RX MUST be false on a transceiver-backed bus: driving TXD
--              from RXD there is positive feedback that latches the whole bus
--              dominant as soon as any node sends a dominant bit.
--
--              This is portable RTL with no board primitives: instantiate it in
--              a board top (see can_node_top.vhd) or in a larger parent design,
--              wiring rx_pin/tx_pin to a CAN transceiver and clk to the parent's
--              fabric clock. Set ClockFrequencyHz to that clock's rate.
--
--              LIMITATIONS: only the ACK bit is transmitted. The data TX path
--              (originating frames: serialize, bit-stuff, CRC-gen, arbitration)
--              is not built yet. The node is a compliant receiver -- it ACKs the
--              frames it accepts -- but cannot itself initiate a transmission.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity can_node is
  generic (
    -- Fabric clock rate. Unless CLKS_PER_BIT is overridden, the bit period is
    -- derived from this for a 125 kbps bus.
    ClockFrequencyHz : integer := 125_000_000;
    CLKS_PER_BIT     : integer := 0;
    -- Drive a dominant ACK on tx_pin for accepted frames. Set false for a
    -- receive-only tap: tx_pin then stays recessive ('1') always.
    ACK_DRIVE : boolean := true;
    -- Mirror rx_pin onto tx_pin outside the ACK slot, so a remote controller on
    -- a two-wire transceiver-less link sees its own transmitted bits come back
    -- and its bit monitoring passes. MUST be false on a transceiver-backed bus
    -- (TXD driven from RXD latches the bus dominant). See the header note.
    ECHO_RX : boolean := false;
    -- Recessive drive style on tx_pin. false = push-pull ('1'), which is what a
    -- transceiver's TXD input wants. true = open-drain ('Z'), for wiring tx_pin
    -- directly onto a shared wired-AND bus node that has its own pull-up (no
    -- transceiver). Never true when tx_pin feeds a transceiver TXD, and never
    -- false when tx_pin shares a node with another driver -- two push-pull
    -- outputs on one net fight each other.
    TX_OPEN_DRAIN : boolean := false
  );
  port (
    clk  : in std_logic; -- system clock
    nRst : in std_logic; -- active-low synchronous reset

    tx_pin : out std_logic; -- CAN TX pin: '0' dominant, '1' or 'Z' recessive (TX_OPEN_DRAIN)
    rx_pin : in std_logic; -- CAN RX pin (async input; synchronized internally)

    rx_id    : out std_logic_vector(10 downto 0); -- received identifier
    rx_dlc   : out std_logic_vector(3 downto 0); -- data length code
    rx_data  : out std_logic_vector(63 downto 0); -- received data bytes
    rx_valid : out std_logic -- 1-clock pulse: good frame ready
  );

end entity can_node;

architecture rtl of can_node is
  function resolve_cpb(freq_hz : integer; override : integer) return integer is
  begin
    if override > 0 then
      return override;
    else
      return freq_hz / 125_000;
    end if;
  end function;
  constant CPB : integer := resolve_cpb(ClockFrequencyHz, CLKS_PER_BIT);

  -- Frame fields in receive order. s_crc_delim/s_ack_delim are extra helper
  -- states so every bit of the trailer is accounted for individually.
  type t_state is (s_idle, s_sof, s_id_base, s_srr_rtr_ide, s_id_ext, s_reserved_bit,
    s_control, s_data, s_crc, s_crc_delim,
    s_ack, s_ack_delim, s_end, s_inter_frame);
  -- In-bit sample instant, in clk cycles from the bit's start edge. The SOF is
  -- sampled this far past its falling edge, which phases every later bit-sample to
  -- the same point. 75% matches the link's 16 tq profile (1 Sync+11 TSeg1+4 TSeg2).
  constant sample_time   : integer := (CPB * 3) / 4;
  constant resync_target : integer := (CPB - 1) - sample_time;
  constant resync_jump   : integer := CPB/4;
  -- clock_count value at a bit boundary: clock_count=0 sits sample_time into a bit,
  -- so the next boundary is CPB-sample_time later. Places the ACK-drive window
  -- correctly regardless of the sample point (= sample_time only when it is 50%).
  constant bit_edge : integer := CPB - sample_time;
  -- CAN CRC-15 generator x^15+x^14+x^10+x^8+x^7+x^4+x^3+1 (0x4599), without the x^15 term.
  constant crc15_poly : std_logic_vector(14 downto 0) := "100010110011001";
  signal state        : t_state                       := s_idle;
  signal clock_count  : integer                       := 0; -- Counts clock cycles for timing the CAN bit periods

  signal bit_period : integer;

  signal rx_sync_meta : std_logic := '1';
  signal rx_sync      : std_logic := '1';
  signal rx_sync_prev : std_logic := '1'; -- rx_sync delayed 1 clk, for edge detect

  -- field storage: signals = registers
  signal id_base : std_logic_vector(10 downto 0); -- Identifier A (11)
  -- signal id_ext   : std_logic_vector(17 downto 0);  -- Identifier B (18, ext only)
  signal rtr, ide, r0        : std_logic;
  signal dlc                 : std_logic_vector(3 downto 0);
  signal data                : std_logic_vector(63 downto 0); -- up to 8 bytes
  signal crc_rx              : std_logic_vector(14 downto 0); -- received CRC
  signal crc_calc            : std_logic_vector(14 downto 0); -- locally computed, live
  signal crc_ok              : std_logic := '0'; -- set when crc_calc = crc_rx
  signal ack_dominant        : std_logic; -- 1 while this node holds the ACK slot dominant
  signal drive_dominant      : std_logic; -- 1 while this node pulls the bus dominant at all
  signal crc_delimiter       : std_logic;
  signal ack_slot            : std_logic;
  signal ack_delimiter       : std_logic;
  signal eof                 : std_logic_vector(6 downto 0);
  signal inter_frame_spacing : std_logic_vector(2 downto 0);

  signal bit_stuffing_cnt : integer range 0 to 5;
  signal prev_bit         : std_logic := '1'; -- last sampled bit, for stuff counting
  signal bit_cnt          : integer range 0 to 64;
  signal data_bits        : integer range 0 to 64 := 0; -- data-field length in bits, from DLC

  attribute mark_debug            : string;
  attribute mark_debug of state   : signal is "true";
  attribute mark_debug of rx_sync : signal is "true";
  attribute mark_debug of crc_ok  : signal is "true";
begin
  -- The ACK slot spans the tail of s_ack (from the bit edge on) plus the head of
  -- s_ack_delim, because a state change happens at the sample point (75% in),
  -- not at the bit boundary.
  ack_dominant <= '1' when ACK_DRIVE and crc_ok = '1'
    and ((state = s_ack and clock_count >= bit_edge)
    or (state = s_ack_delim and clock_count < bit_edge))
    else
    '0';

  -- This node pulls the bus dominant for its ACK, and on an ECHO_RX link also
  -- whenever the bus itself is dominant (the wired-AND mirror).
  drive_dominant <= '1' when ack_dominant = '1' or (ECHO_RX and rx_sync = '0')
    else
    '0';

  tx_pin <= '0' when drive_dominant = '1' else
    'Z' when TX_OPEN_DRAIN else
    '1';

  bit_period <= sample_time when state = s_sof else
    CPB - 1;

  -- 2-FF synchronizer for the asynchronous rx_pin input.
  RX_SYNC_FF : process (clk)
  begin
    if rising_edge(clk) then
      if nRst = '0' then
        rx_sync_meta <= '1';
        rx_sync      <= '1';
        rx_sync_prev <= '1';
      else
        rx_sync_meta <= rx_pin;
        rx_sync      <= rx_sync_meta;
        rx_sync_prev <= rx_sync;
      end if;
    end if;
  end process RX_SYNC_FF;

  CAN_RX : process (clk)
    variable crc_next : std_logic; -- CRC feedback bit: input XOR crc_calc MSB
    variable dlc_val  : unsigned(3 downto 0); -- decoded data length code (0..15)
  begin
    if rising_edge(clk) then
      rx_valid <= '0';
      if nRst = '0' then
        state       <= s_idle;
        clock_count <= 0;
        bit_cnt     <= 0;
        data_bits   <= 0;
        crc_calc    <= (others => '0');
        crc_ok      <= '0'; -- never ACK off a stale CRC result after reset

      elsif state = s_idle then
        clock_count <= 0;
        bit_cnt     <= 0;
        crc_calc    <= (others => '0'); -- clear before each frame; SOF is the first CRC bit
        data        <= (others => '0');
        if rx_sync = '0' then
          state <= s_sof;
        end if;
      elsif clock_count < bit_period then
        if (state >= s_sof and state <= s_crc_delim)
          and rx_sync = '0' and rx_sync_prev = '1' then
          if clock_count > resync_target then
            if clock_count - resync_target > resync_jump then
              clock_count <= clock_count - resync_jump;
            else
              clock_count <= resync_target;
            end if;
          elsif clock_count < resync_target then
            if resync_target - clock_count > resync_jump then
              clock_count <= clock_count + resync_jump;
            else
              clock_count <= resync_target;
            end if;
          else
            clock_count <= clock_count + 1;
          end if;
        else
          clock_count <= clock_count + 1;
        end if;
      else
        clock_count                 <= 0;
        -- Stuff bits are inserted anywhere in SOF..CRC, which includes right
        -- after the last CRC bit -- by then state is already s_crc_delim, so the
        -- de-stuff window has to reach that state or the stuff bit gets eaten as
        -- the CRC delimiter and everything after it lands one bit early.
        if state >= s_sof and state <= s_crc_delim and bit_stuffing_cnt = 5 then
          null;
        else
          -- CRC-15 over the de-stuffed bits from SOF through the data field
          -- (the CRC field itself is excluded). Frozen once state passes s_data.
          if state >= s_sof and state <= s_data then
            crc_next := rx_sync xor crc_calc(14);
            if crc_next = '1' then
              crc_calc <= (crc_calc(13 downto 0) & '0') xor crc15_poly;
            else
              crc_calc <= (crc_calc(13 downto 0) & '0');
            end if;
          end if;

          case state is

            when s_sof =>
              if rx_sync = '0' then
                state   <= s_id_base;
                bit_cnt <= 0;
              else
                state <= s_idle;
              end if;

            when s_id_base =>
              id_base <= id_base(9 downto 0) & rx_sync;
              if bit_cnt = 10 then
                state <= s_srr_rtr_ide;
              else
                bit_cnt <= bit_cnt + 1;
              end if;

            when s_srr_rtr_ide =>
              rtr   <= rx_sync;
              state <= s_id_ext;

            when s_id_ext =>
              ide     <= rx_sync;
              state   <= s_reserved_bit;
              bit_cnt <= 0;

            when s_reserved_bit =>
              r0      <= rx_sync;
              state   <= s_control;
              bit_cnt <= 0;

            when s_control =>
              dlc <= dlc(2 downto 0) & rx_sync; -- MSB first; full DLC ready when bit_cnt = 3
              if bit_cnt = 3 then
                bit_cnt <= 0;
                -- Data length from DLC: DLC>8 still means 8 bytes; remote frames
                -- (RTR=1) and DLC=0 carry no data field at all -> straight to CRC.
                dlc_val := unsigned(dlc(2 downto 0) & rx_sync);
                if dlc_val > 8 then
                  data_bits <= 64;
                else
                  data_bits <= to_integer(dlc_val) * 8;
                end if;
                if rtr = '1' or dlc_val = 0 then
                  state <= s_crc;
                else
                  state <= s_data;
                end if;
              else
                bit_cnt <= bit_cnt + 1;
              end if;

            when s_data =>
              data <= data(62 downto 0) & rx_sync;
              if bit_cnt = data_bits - 1 then
                state   <= s_crc;
                bit_cnt <= 0;
              else
                bit_cnt <= bit_cnt + 1;
              end if;

            when s_crc =>
              crc_rx <= crc_rx(13 downto 0) & rx_sync; -- MSB first, to match crc_calc
              if bit_cnt = 14 then
                state   <= s_crc_delim;
                bit_cnt <= 0;
              else
                bit_cnt <= bit_cnt + 1;
              end if;

            when s_crc_delim =>
              crc_delimiter <= rx_sync;
              if crc_calc = crc_rx then -- crc_rx now fully loaded, crc_calc frozen
                crc_ok <= '1';
              else
                crc_ok <= '0';
              end if;
              state <= s_ack;

            when s_ack =>
              ack_slot <= rx_sync;
              state    <= s_ack_delim;

            when s_ack_delim =>
              ack_delimiter <= rx_sync;
              state         <= s_end;
              bit_cnt       <= 0;

            when s_end =>
              eof(bit_cnt) <= rx_sync;
              if bit_cnt = 6 then
                state   <= s_inter_frame;
                bit_cnt <= 0;
                if crc_ok = '1' then
                  rx_id    <= id_base;
                  rx_dlc   <= dlc;
                  rx_data  <= data;
                  rx_valid <= '1';
                end if;
              else
                bit_cnt <= bit_cnt + 1;
              end if;

            when s_inter_frame =>
              inter_frame_spacing(bit_cnt) <= rx_sync;
              if bit_cnt = 2 then
                state <= s_idle;
              else
                bit_cnt <= bit_cnt + 1;
              end if;

            when s_idle =>
              null;
          end case;
        end if;
      end if;
    end if;
  end process CAN_RX;

  BIT_STUFFING : process (clk)
  begin
    if rising_edge(clk) then
      if nRst = '0' then
        bit_stuffing_cnt               <= 1;
        prev_bit                       <= '1';
      elsif state >= s_sof and state <= s_crc_delim then
        -- Must track one state past s_crc so the counter still reads 5 when the
        -- de-stuff check above runs in s_crc_delim.
        if clock_count = bit_period then
          if rx_sync = prev_bit then
            if bit_stuffing_cnt < 5 then
              bit_stuffing_cnt <= bit_stuffing_cnt + 1;
            end if;
          else
            bit_stuffing_cnt <= 1;
          end if;
          prev_bit <= rx_sync;
        end if;
      else
        bit_stuffing_cnt <= 1;
        prev_bit         <= '1';
      end if;
    end if;
  end process BIT_STUFFING;
end architecture rtl;
