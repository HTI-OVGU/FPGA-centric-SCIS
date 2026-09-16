library ieee;
use ieee.std_logic_1164.all;
use IEEE.NUMERIC_STD.all;

entity w5500_state_machine is
  generic (
    socket_amount : integer := 1; -- all 8 sockets to be opened
    DEFAULT_ROUTINE : string := "receive_first"; -- choose between "receive_first" or "send_first"
    mac_address : std_logic_vector(47 downto 0) := x"D47F39AE92B1";
    source_ip_address : std_logic_vector(31 downto 0) := x"C0A80264"; --local ip address   192 168 2 100
    dest_ip_address   : std_logic_vector(31 downto 0) := x"C0A8026A"; --destination ip address  192 168 2 106
    source_udp_port   : std_logic_vector(15 downto 0) := x"2401"; -- local udp port   217
    dest_udp_port     : std_logic_vector(15 downto 0) := x"2401"; --destination udp port   217

    -- How many 9-byte metric packets may accumulate in the W5500's TX buffer
    -- before SEND is issued. The nine SPI transactions around a datagram cost
    -- ~25 us whatever it carries, so this divides that cost by N. Keep
    -- N * 9 below minimum_free_tx_buffer_memory (256): 16 packets = 144 bytes.
    TX_BATCH_MAX_PACKETS : integer := 16;

    -- Send a partially filled datagram after this many clocks without an append,
    -- provided the transmit stream has nothing else to offer. 300 at 30 MHz is
    -- 10 us -- the gap between packets at 100 000 packets/s. Above that rate the
    -- batch fills first and this never fires; below it, this is what bounds the
    -- added latency instead of letting a packet wait for companions that are not
    -- coming.
    TX_FLUSH_IDLE_CLKS : integer := 300;

    -- Hard ceiling on how long a datagram may stay open, checked even while the
    -- stream is busy. TX_FLUSH_IDLE_CLKS alone is not enough: the arbiter
    -- upstream is strict lowest-index-first, so a saturated socket 0 can keep
    -- the stream permanently non-empty and a partly filled datagram on a higher
    -- socket would then never reach the idle test at all -- its metrics would
    -- sit in the chip's transmit buffer until that socket happened to receive
    -- TX_BATCH_MAX_PACKETS more.
    --
    -- It has to sit well above the interval at which a *busy* socket gets its
    -- turn, or a socket merely queueing behind the others is mistaken for idle
    -- and batching collapses again. One append is 12 SPI bytes (3 header, 9
    -- payload) at 15 MHz = 6.4 us, and closing a datagram costs about 15 us
    -- more, so waiting behind seven other sockets is roughly 60 us = 1800
    -- clocks at 30 MHz. 8192 clocks is 273 us: comfortably clear of that, and
    -- far below anything the slow-control loop notices.
    TX_MAX_OPEN_CLKS : integer := 8192;

    -- Watchdog: how long the machine may sit in one state before it is forced
    -- back to a known one. Six states wait on a condition with no else branch
    -- and no timeout, so a condition that never arrives parks the controller
    -- until the board is power-cycled. None of them is known to hang today --
    -- the wedge that was actually reproduced is the Sn_RX_RSR width, and that
    -- one skips a socket rather than stopping the machine -- but a controller
    -- whose only recovery is a power cycle should not rely on that list being
    -- complete. The longest legitimate state is the receive-buffer read: 2048
    -- bytes at 533 ns each is 1.1 ms, so this has to sit well above it.
    -- 65535 clocks at 30 MHz is 2.18 ms.
    WATCHDOG_CLKS : integer := 65535
  );
  port (
    clk      : in std_logic;
    reset    : in std_logic := '0';
    spi_busy : in std_logic := '0';

    tdata  : out std_logic_vector (7 downto 0); -- data to send
    tvalid : out std_logic; -- axi stream from statemachine to spi master
    tready : in std_logic;
    tlast  : out std_logic;

    rdata  : in std_logic_vector (7 downto 0); -- data received
    rvalid : in std_logic; -- axi stream from spi master to state machine
    rready : out std_logic;
    rlast  : in std_logic;

    ext_pl_tdata  : in std_logic_vector (7 downto 0); -- payload data to send from external source
    ext_pl_tready : out std_logic;
    ext_pl_tvalid : in std_logic;
    ext_pl_tlast  : in std_logic;
    ext_pl_tuser  : in std_logic_vector (2 downto 0);

    ext_pl_rdata  : out std_logic_vector (7 downto 0); -- payload data that has been received from the w5500 provided for external source
    ext_pl_rready : in std_logic;
    ext_pl_rvalid : out std_logic;
    ext_pl_rlast  : out std_logic;
    ext_pl_ruser  : out std_logic_vector (2 downto 0)
  );

end entity w5500_state_machine;

architecture behavioral of w5500_state_machine is

  --spi master states
  type W5500_state_type is (
    RESET_STATE,
    RESET_W5500_CHIP_STATE,
    SET_GATEWAY_STATE,
    SET_SUBNET_MASK_STATE,
    SET_MAC_ADDRESS_STATE_1,
    SET_MAC_ADDRESS_STATE_2,
    SET_SOURCE_IP_ADDRESS,
    SET_UDP_MODE,
    OPEN_UDP_SOCKET,
    SET_SOURCE_SOCKET_PORT,
    SET_DESTINATION_IP_ADDRESS,
    SET_DESTINATION_UDP_PORT,
    READ_TX_FREE_SIZE_REGISTER,
    WRITE_TX_DATA_TO_BUFFER,
    GET_TX_FREE_BUFFER_SIZE,
    GET_TX_WRITE_POINTER,
    UPDATE_TX_WRITE_POINTER_AFTER_WRITE,
    UPDATE_RX_READ_POINTER_AFTER_BUFFER_READ,
    GET_RX_SOCKET_RECEIVED_DATA_SIZE,
    CHECK_IF_TX_WR_POINTER_HAS_BEEN_UPDATED,
    WAIT_FOR_REQUESTED_RX_SOCKET_DATA_SIZE,
    CHECK_IF_RECEIVED_DATA_IS_AVAILABLE_STATE,
    GET_RX_READ_POINTER_STATE,
    GET_UPDATED_TX_WR_POINTER_BEFORE_SEND,
    WAIT_FOR_EXT_DATA_HANDLER_TO_FINISH_READING_FROM_FIFO,
    CHECK_TX_READ_POINTER_AFTER_SUCCESSFUL_TRANSMISSION,
    ISSUE_READ_COMMAND_TO_UPDATE_RX_WRITE_POINTER,
    CHECK_SOCKET_INTERRUPT_REGISTER_RETURNED_VALUE,
    CHECK_IF_UDP_SOCKET_IS_INITIALIZED,
    GET_SOCKET_INTERRUPT_REGISTER,
    WAIT_FOR_TX_WRITE_POINTER_TO_BE_RECEIVED,
    ISSUE_SEND_COMMAND,
    GET_SOCKET_STATUS_THROUGH_SN_SR,
    CHECK_IF_FREE_SIZE_IS_AVAILABLE,
    WAIT_FOR_SOCKET_INTERRUPT_REGISTER_TO_BE_RECEIVED,
    CLEAR_INTERRUPT_FLAGS_FROM_SOCKET_INTERRUPT_REGISTER,
    CHECK_IF_EXTERNAL_DATA_SOURCE_HAS_DATA,
    READ_HEADER_AND_PAYLOAD_FROM_RX_BUFFER_STATE,
    WAIT_FOR_RX_READ_POINTER_TO_BE_RECEIVED,
    CHECK_SOCKET_STATUS_AFTER_INIT_PIPELINE,
    SECOND_RESET_W5500_CHIP_STATE,
    RETURN_TO_DEFAULT_ROUTINE,
    LOOP_THROUGH_ALL_SOCKET_MODE_REGISTERS,
    LOOP_THROUGH_ALL_SOURCE_PORT_REGISTERS,
    LOOP_TO_OPEN_ALL_UDP_SOCKETS
  );

  signal w5500_control_flow_state, next_w5500_control_flow_state, prev_w5500_control_flow_state : W5500_state_type;

  signal prev_spi_busy : std_logic := '0';
  signal spi_transaction_finished : std_logic := '0';

  signal spi_payload_data        : std_logic_vector(31 downto 0) := (others => '0');
  signal shift_payload_buffer           : std_logic_vector(31 downto 0) := (others => '0'); -- buffer for second process
  signal spi_payload_data_byte_length        : integer range 0 to 4095; -- this has to be set every time the raw_payload_buffer is updated.
  signal byte_length_buffer             : integer   := 0; -- buffer for second process
  signal prev_payload_data_has_been_set : std_logic := '0';
  signal spi_payload_data_was_set      : std_logic := '0';

  --tx data payload signals
  signal tx_payload_data  : std_logic_vector(7 downto 0);
  signal tx_payload_ready : std_logic;
  signal tx_payload_valid : std_logic;
  signal tx_payload_last  : std_logic := '0';

  signal received_payload_buffer : std_logic_vector(31 downto 0) := (others => '0'); -- buffer for second process

  --rx data payload signals
  signal rx_payload_data  : std_logic_vector(7 downto 0);
  signal rx_payload_ready : std_logic;
  signal rx_payload_valid : std_logic;
  signal rx_payload_last  : std_logic := '0';

  signal spi_header_data  : std_logic_vector(23 downto 0);
  signal spi_header_valid : std_logic;

  signal rready_int_buffer : std_logic := '0';

  signal ext_pl_tready_int : std_logic := '0';

  -- Sn_RX_RSR counts bytes waiting in the socket's receive buffer, and that
  -- buffer is 2048 bytes (the chip default -- Sn_RXBUF_SIZE is never written),
  -- so the value reaches 2048 and needs twelve bits. At eleven it wrapped: a
  -- completely full buffer read back as zero, CHECK_IF_RECEIVED_DATA_IS_AVAILABLE
  -- concluded the socket was empty and skipped it, and it was never read again.
  -- The socket stayed full, the chip dropped everything addressed to it, and
  -- from outside that looks exactly like "the W5500 closed the socket".
  -- tb_w5500_tx with G_RX_FILL = 2048 is the regression.
  signal rx_received_size_reg : std_logic_vector(11 downto 0);
  signal rx_pointer_reg       : std_logic_vector(15 downto 0);
  signal updated_rx_pointer_reg : std_logic_vector(15 downto 0);

  -- PASSTHROUGH MODE COUNTERS
  signal bytes_counted_during_tx_fifo_passthrough    : integer range 0 to 1023;
  signal ext_pl_tlast_was_received                   : std_logic := '0';
  signal requested_streammanager_state               : std_logic_vector(1 downto 0);
  signal ptm_data_being_written_to_w5500             : std_logic;
  signal last_rx_packet_from_w5500_has_been_received : std_logic;

  -- Datagram accumulation, tracked per socket. Packets are written into the
  -- W5500's transmit buffer as they arrive, each as its own short SPI
  -- transaction, and Sn_TX_WR is only advanced (and SEND issued) once the batch
  -- is closed. Because every write is self-contained, a gap in the source
  -- between packets cannot land inside an open SPI transaction.
  --
  -- Why per socket rather than one batch at a time: the batch was single, so a
  -- packet for a different socket closed whatever was accumulating. Traffic
  -- spread over all eight sockets alternates almost every packet -- the arbiter
  -- in metric_packet_manager re-checks priority after each one -- so every
  -- datagram went out holding exactly one metric and the batching bought
  -- nothing. That is why the eight-socket spread measured *slower* than one hot
  -- socket. Each socket in the chip has its own transmit buffer and its own
  -- Sn_TX_WR, so batches on different sockets are genuinely independent and
  -- only need separate bookkeeping here.
  type socket_ptr_t     is array (0 to 7) of unsigned(15 downto 0);
  type socket_count_t   is array (0 to 7) of integer range 0 to TX_BATCH_MAX_PACKETS;
  type socket_timer_t   is array (0 to 7) of integer range 0 to TX_MAX_OPEN_CLKS;

  signal batch_open    : std_logic_vector(7 downto 0) := (others => '0');
  -- Where this socket's next payload byte goes: Sn_TX_WR as read when the
  -- datagram was opened, advanced by every byte written since. It doubles as the
  -- value Sn_TX_WR is set to when the datagram closes, so the opening pointer
  -- and the running length never need to be kept apart.
  signal tx_wr_cur     : socket_ptr_t   := (others => (others => '0'));
  signal batch_packets : socket_count_t := (others => 0);
  -- A datagram opened by something that is not a V01 record (telemetry_sender
  -- emits bare-ASCII alerts) must carry that one payload alone: admitting a
  -- metric behind it would leave the receiver parsing records at the wrong
  -- offset for the rest of the datagram.
  signal batch_solo    : std_logic_vector(7 downto 0) := (others => '0');
  -- Clocks since each socket's last append; one counter serves both flush tests.
  signal flush_timer   : socket_timer_t := (others => 0);
  -- Quiet long enough to go out if there is nothing better to do.
  signal idle_socket   : std_logic_vector(2 downto 0) := "000";
  signal idle_any      : std_logic := '0';
  -- Open long enough that it goes out even while the stream is busy.
  signal stale_socket  : std_logic_vector(2 downto 0) := "000";
  signal stale_any     : std_logic := '0';

  -- Sn_DIPR and Sn_DPORT are per-socket registers and hold their value, while
  -- the values written are synthesis-time constants -- one IP for every socket,
  -- and a port that is just the base plus the socket number. Rewriting them on
  -- every datagram costs 12 bytes of SPI (6.4 us at 15 MHz) to store what is
  -- already there. One bit per socket, so each is programmed exactly once after
  -- reset; a single "last socket" register would lose the saving as soon as
  -- traffic alternates between sockets.
  signal dest_regs_done : std_logic_vector(7 downto 0) := (others => '0');

  -- Watchdog state. init_done keeps the escape from throwing the machine out of
  -- the chip-configuration pipeline, which would leave the W5500 unconfigured:
  -- before the first pass through RETURN_TO_DEFAULT_ROUTINE the only safe
  -- recovery is to start the whole initialisation again.
  signal watchdog   : integer range 0 to WATCHDOG_CLKS := 0;
  signal init_done  : std_logic := '0';

  -- constants

  constant gateway_address   : std_logic_vector(31 downto 0) := x"C0A80201"; -- 192.168.2.1
  constant subnet_mask_address : std_logic_vector(31 downto 0) := x"FFFFFF00"; -- 255 255 255 00
  constant minimum_free_tx_buffer_memory : unsigned(8 downto 0) := to_unsigned(256, 9);

  -- Socket counters
  signal current_socket_counter : std_logic_vector(2 downto 0) := "000";
  
  component w5500_axi_data_streamer is
    port (
      clk                : in std_logic;
      reset              : in std_logic;
      m_spi_header_data  : in std_logic_vector(23 downto 0); -- the first 24 bits to transmit before continuing with the payload
      m_spi_header_valid : in std_logic;

      m_axis_tready : out std_logic; -- payload ready AXIStream ready
      m_axis_tvalid : in std_logic; --payload valid AXISTream valid
      m_axis_tdata  : in std_logic_vector(7 downto 0); -- 32-bit payload to be sent (doesn't matter if from state machine or external)
      m_axis_tlast  : in std_logic; -- payload last bit of axiStream

      m_axis_rready : in std_logic; -- rx_payload ready
      m_axis_rvalid : out std_logic;
      m_axis_rdata  : out std_logic_vector(7 downto 0);
      m_axis_rlast  : out std_logic;

      n_axis_tready : in std_logic; -- FROM SPI Master (AXI Stream TREADY)
      n_axis_tvalid : out std_logic; -- To SPI Master (AXI Stream TVALID)
      n_axis_tdata  : out std_logic_vector(7 downto 0); -- To SPI Master (AXI Stream TDATA)
      n_axis_tlast  : out std_logic;

      n_axis_rready : out std_logic; -- To SPI Master (AXI Stream RREADY)
      n_axis_rvalid : in std_logic; -- From SPI Master (AXI Stream RVALID)
      n_axis_rdata  : in std_logic_vector(7 downto 0); -- From SPI Master (AXI Stream RREADY)
      n_axis_rlast  : in std_logic
    );
  end component;

  component w5500_stream_manager is
    port (
      clk                           : in std_logic;
      reset                         : in std_logic;
      requested_streammanager_state : in std_logic_vector(1 downto 0);

      ext_pl_tdata  : in std_logic_vector(7 downto 0); -- data from the external data handler
      ext_pl_tvalid : in std_logic;
      ext_pl_tready : out std_logic;
      ext_pl_tlast  : in std_logic;

      ext_pl_rdata  : out std_logic_vector(7 downto 0); -- data for the external data handler
      ext_pl_rvalid : out std_logic;
      ext_pl_rlast  : out std_logic;
      ext_pl_rready : in std_logic;

      tx_payload_data  : out std_logic_vector(7 downto 0); -- data from the stream manager to the spi data streamer
      tx_payload_ready : in std_logic;
      tx_payload_valid : out std_logic;
      tx_payload_last  : out std_logic;

      rx_payload_data  : in std_logic_vector(7 downto 0); -- data from the spi data streamer to the stream manager
      rx_payload_valid : in std_logic;
      rx_payload_ready : out std_logic;
      rx_payload_last  : in std_logic;

      received_payload_buffer : out std_logic_vector(31 downto 0);

      spi_header_data  : in std_logic_vector(23 downto 0); -- SPI Header data from the FSM
      spi_header_valid : out std_logic;

      spi_data_buffer           : in std_logic_vector(31 downto 0); -- raw spi payload data from FSM
      spi_data_length           : in integer range 0 to 4095; -- amount of payload bytes to be transmitted
      payload_data_has_been_set : in std_logic;

      ptm_data_being_written_to_w5500             : out std_logic;
      last_rx_packet_from_w5500_has_been_received : out std_logic
    );
  end component;

begin

  ext_pl_tready <= ext_pl_tready_int;

  -- Idle gap before a partially filled datagram goes out anyway, measured
  -- separately for every socket: a socket that has gone quiet must not be held
  -- open by traffic on a different one.
  p_flush_timer : process (clk)
  begin
    if rising_edge(clk) then
      for s in 0 to 7 loop
        -- Reset while a packet is actually being written to this socket, so this
        -- measures the quiet since that socket's last append. Keying it off
        -- ext_pl_tvalid instead was wrong: that signal is not a reliable
        -- "something is coming" and held the timer at zero, so a partial
        -- datagram never went out on timeout at all.
        if reset = '1' or batch_open(s) = '0'
           or (w5500_control_flow_state = WRITE_TX_DATA_TO_BUFFER
               and to_integer(unsigned(current_socket_counter)) = s) then
          flush_timer(s) <= 0;
        elsif flush_timer(s) < TX_MAX_OPEN_CLKS then
          -- Saturates at the larger of the two thresholds: capping at
          -- TX_FLUSH_IDLE_CLKS would stop the count before it could ever satisfy
          -- the stale test, leaving the starvation escape permanently unarmed.
          flush_timer(s) <= flush_timer(s) + 1;
        end if;
      end loop;
    end if;
  end process;

  -- Which socket gets flushed when several are due at once. Scanning downwards
  -- leaves the lowest index selected, matching the strict lowest-index-wins
  -- priority the output arbiter upstream already uses.
  p_flush_select : process (flush_timer, batch_open)
    variable idle_sel  : std_logic_vector(2 downto 0);
    variable idle_hit  : std_logic;
    variable stale_sel : std_logic_vector(2 downto 0);
    variable stale_hit : std_logic;
  begin
    idle_sel  := "000";
    idle_hit  := '0';
    stale_sel := "000";
    stale_hit := '0';
    for s in 7 downto 0 loop
      if batch_open(s) = '1' and flush_timer(s) >= TX_FLUSH_IDLE_CLKS then
        idle_sel := std_logic_vector(to_unsigned(s, 3));
        idle_hit := '1';
      end if;
      if batch_open(s) = '1' and flush_timer(s) >= TX_MAX_OPEN_CLKS then
        stale_sel := std_logic_vector(to_unsigned(s, 3));
        stale_hit := '1';
      end if;
    end loop;
    idle_socket  <= idle_sel;
    idle_any     <= idle_hit;
    stale_socket <= stale_sel;
    stale_any    <= stale_hit;
  end process;

  -- Counts how long the control flow has stood still. Any state change clears
  -- it, so in normal operation it never gets near the limit: the longest state
  -- is a receive-buffer read at about 1.1 ms against a 2.18 ms threshold.
  p_watchdog : process (clk)
  begin
    if rising_edge(clk) then
      if reset = '1' or w5500_control_flow_state /= prev_w5500_control_flow_state then
        watchdog <= 0;
      elsif watchdog < WATCHDOG_CLKS then
        watchdog <= watchdog + 1;
      end if;
    end if;
  end process;

  u_w5500_axi_data_streamer : w5500_axi_data_streamer
  port map
  (
    clk                => clk,
    reset              => reset,
    m_spi_header_data  => spi_header_data, -- the first 24 bits to transmit before continuing with the payload
    m_spi_header_valid => spi_header_valid,

    m_axis_tready => tx_payload_ready, -- payload ready AXIStream ready
    m_axis_tvalid => tx_payload_valid, --payload valid AXISTream valid
    m_axis_tdata  => tx_payload_data, -- 8 bit payload data AXIS tdata
    m_axis_tlast  => tx_payload_last, -- AXIStream last

    m_axis_rready => rx_payload_ready,
    m_axis_rvalid => rx_payload_valid,
    m_axis_rdata  => rx_payload_data,
    m_axis_rlast  => rx_payload_last,

    -- AXIS for communication with the SPI Master:
    n_axis_tready => tready,
    n_axis_tvalid => tvalid,
    n_axis_tdata  => tdata,
    n_axis_tlast  => tlast,

    n_axis_rready => rready_int_buffer,
    n_axis_rvalid => rvalid,
    n_axis_rdata  => rdata,
    n_axis_rlast  => rlast
  );

  rready <= rready_int_buffer;

  -- state memory
  process (clk, reset)
  begin
    if(rising_edge(clk)) then 
      if (reset = '1') then
        w5500_control_flow_state <= RESET_STATE;
        prev_w5500_control_flow_state <= RESET_STATE;
      else 
        w5500_control_flow_state <= next_w5500_control_flow_state;
        prev_w5500_control_flow_state <= w5500_control_flow_state;
      end if;
    end if;
  end process;

  ------ State Machine Transistion logic-------
  process (clk, reset, w5500_control_flow_state, spi_busy, spi_header_data)
    -- Socket of the packet being offered on the external stream right now.
    -- current_socket_counter cannot stand in for it: it is a signal assigned in
    -- this same process, so within the cycle that redirects it to ext_pl_tuser
    -- it still reads back as whatever the RX poll left behind.
    variable arriving_socket : integer range 0 to 7 := 0;
    -- Socket whose datagram the transmit states are working on.
    variable tx_socket       : integer range 0 to 7 := 0;
  begin

    if rising_edge(clk) then

      tx_socket := to_integer(unsigned(current_socket_counter));

      spi_transaction_finished <= (not spi_busy) and prev_spi_busy;

      case w5500_control_flow_state is
        when RESET_STATE =>
          if (tx_payload_ready = '1') then --when the FIFOs in the W5500 stream manager are ready, then we can continue
            next_w5500_control_flow_state               <= RESET_W5500_CHIP_STATE;
            requested_streammanager_state <= "00"; -- this means CONTROLLER PHASE to the stream manager
            rx_received_size_reg          <= (others => '0');
            rx_pointer_reg                <= (others => '0');
            updated_rx_pointer_reg        <= (others => '0');
            tx_wr_cur                     <= (others => (others => '0'));
            current_socket_counter        <= "000";
          end if;

        when RESET_W5500_CHIP_STATE =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 1;
            spi_header_data           <= x"0000" & "00000" & '1' & "00"; -- Mode Register 0x0000 -- + "00000" (BSB for common register) + '1' (write) + "00" for vdm
            spi_payload_data   <= x"80000000";
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= SET_GATEWAY_STATE;
            spi_payload_data_was_set <= '0';
          end if;


        when SET_GATEWAY_STATE =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 4;
            spi_header_data           <= x"0001" & "00000" & '1' & "00"; --gateway address register 0x0001 + CommonRegister BSB "00000" + write"1" + "00" VDM
            spi_payload_data   <= gateway_address;
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= SET_SUBNET_MASK_STATE;
            spi_payload_data_was_set <= '0';
          end if;


        when SET_SUBNET_MASK_STATE =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 4;
            spi_header_data           <= x"0005" & "00000" & '1' & "00";
            spi_payload_data   <= subnet_mask_address;
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= SET_MAC_ADDRESS_STATE_1;
            spi_payload_data_was_set <= '0';
          end if;

        when SET_MAC_ADDRESS_STATE_1 => -- Part 1 writing 4 bytes of the 6 byte MAC address
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 4;
            spi_header_data           <= x"0009" & "00000" & '1' & "00";
            spi_payload_data   <= mac_address(47 downto 16); -- first 4 bytes of mac address
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= SET_MAC_ADDRESS_STATE_2;
            spi_payload_data_was_set <= '0';
          end if;


        when SET_MAC_ADDRESS_STATE_2 => -- Part 2 writing 2 bytes of the 6 byte MAC address
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 2;
            spi_header_data           <= x"000D" & "00000" & '1' & "00";
            spi_payload_data   <= mac_address(15 downto 0) & x"0000"; -- first 4 bytes of mac address
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= SET_SOURCE_IP_ADDRESS;
            spi_payload_data_was_set <= '0';
          end if;


        when SET_SOURCE_IP_ADDRESS =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 4;
            spi_header_data           <= x"000F" & "00000" & '1' & "00";
            spi_payload_data   <= source_ip_address;
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= SET_UDP_MODE;
            spi_payload_data_was_set <= '0';
          end if;

        when SET_UDP_MODE =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) or 
          (spi_transaction_finished = '1') then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 1;
            spi_header_data           <= x"0000" & current_socket_counter & "01" & '1' & "00";
            spi_payload_data   <= x"02000000";
          end if;

          if (spi_transaction_finished = '1') then
            spi_payload_data_was_set <= '0';
            next_w5500_control_flow_state        <= LOOP_THROUGH_ALL_SOCKET_MODE_REGISTERS;
          end if;

        when LOOP_THROUGH_ALL_SOCKET_MODE_REGISTERS => 
          if(prev_w5500_control_flow_state /= w5500_control_flow_state) then --when first entering state
            if(unsigned(current_socket_counter) = socket_amount - 1) then 
              next_w5500_control_flow_state        <= SET_SOURCE_SOCKET_PORT;
              current_socket_counter <= "000";
            else 
              next_w5500_control_flow_state        <= SET_UDP_MODE;
              current_socket_counter <= std_logic_vector(unsigned(current_socket_counter) + 1);
            end if;
          end if;

        when SET_SOURCE_SOCKET_PORT =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) or 
          (spi_transaction_finished = '1') then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 2;
            spi_header_data           <= x"0004" & current_socket_counter & "01" & '1' & "00";
            spi_payload_data   <= std_logic_vector(unsigned(source_udp_port) + unsigned(current_socket_counter)) & x"0000";
            -- sets the UDP source ports for each socket. Socket Port is source_port + current_socket_counter
          end if;

          if (spi_transaction_finished = '1') then
            spi_payload_data_was_set <= '0';
            next_w5500_control_flow_state        <= LOOP_THROUGH_ALL_SOURCE_PORT_REGISTERS;
          end if;

        when LOOP_THROUGH_ALL_SOURCE_PORT_REGISTERS =>
          if(prev_w5500_control_flow_state /= w5500_control_flow_state) then --when first entering state
            if(unsigned(current_socket_counter) = socket_amount - 1) then 
              next_w5500_control_flow_state        <= OPEN_UDP_SOCKET;
              current_socket_counter <= "000";
            else 
              next_w5500_control_flow_state        <= SET_SOURCE_SOCKET_PORT;
              current_socket_counter <= std_logic_vector(unsigned(current_socket_counter) + 1);
            end if;
          end if;

        when OPEN_UDP_SOCKET =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 1;
            spi_header_data           <= x"0001" & current_socket_counter & "01" & '1' & "00";
            spi_payload_data   <= x"01000000";
            -- sets the UDP source ports for each socket. Socket Port is source_port + current_socket_counter
          end if;

          if (spi_transaction_finished = '1') then
            spi_payload_data_was_set <= '0';
            next_w5500_control_flow_state        <= LOOP_TO_OPEN_ALL_UDP_SOCKETS;
          end if;

          when LOOP_TO_OPEN_ALL_UDP_SOCKETS =>
            if(prev_w5500_control_flow_state /= w5500_control_flow_state) then --when first entering state
              if(unsigned(current_socket_counter) = socket_amount - 1) then 
                next_w5500_control_flow_state        <= RETURN_TO_DEFAULT_ROUTINE;
                current_socket_counter <= "000";
              else 
                next_w5500_control_flow_state        <= OPEN_UDP_SOCKET;
                current_socket_counter <= std_logic_vector(unsigned(current_socket_counter) + 1);
              end if;
            end if;
          
        when RETURN_TO_DEFAULT_ROUTINE => 
          if(DEFAULT_ROUTINE = "send_first") then
            next_w5500_control_flow_state <= CHECK_IF_EXTERNAL_DATA_SOURCE_HAS_DATA;
          else 
            if(unsigned(current_socket_counter) = socket_amount) then -- when all sockets have been "read", start at 0 again and check for data to send
              next_w5500_control_flow_state <= CHECK_IF_EXTERNAL_DATA_SOURCE_HAS_DATA;
              current_socket_counter <= "000";
            else 
              next_w5500_control_flow_state <= GET_RX_SOCKET_RECEIVED_DATA_SIZE;
            end if;
          end if;

        when CHECK_IF_EXTERNAL_DATA_SOURCE_HAS_DATA =>
          if (stale_any = '1') then
            -- Checked before new arrivals on purpose. A datagram that has been
            -- open this long has to go out even though the stream still has work
            -- to offer, because the socket it belongs to may be starved at the
            -- arbiter indefinitely and would otherwise never be revisited.
            current_socket_counter        <= stale_socket;
            next_w5500_control_flow_state <= UPDATE_TX_WRITE_POINTER_AFTER_WRITE;
          elsif (ext_pl_tvalid = '1' and tx_payload_ready = '1') then -- if data on the external TX AXIstream is valid and the payload fifo is ready, then continue
            arriving_socket := to_integer(unsigned(ext_pl_tuser));
            current_socket_counter <= ext_pl_tuser;

            if (batch_open(arriving_socket) = '1') then
              -- That socket already has a datagram accumulating, so this packet
              -- can join it if it is a metric record and there is still room.
              if (ext_pl_tdata = x"56" and batch_solo(arriving_socket) = '0'
                  and batch_packets(arriving_socket) < TX_BATCH_MAX_PACKETS) then
                requested_streammanager_state <= "01"; -- TX_FIFO_PASSTHROUGH_MODE
                next_w5500_control_flow_state <= WRITE_TX_DATA_TO_BUFFER;
              else
                -- Full, or an alert that must travel alone: close this socket's
                -- datagram now. The packet stays offered on the stream and is
                -- taken on a later pass, into a fresh datagram.
                next_w5500_control_flow_state <= UPDATE_TX_WRITE_POINTER_AFTER_WRITE;
              end if;
            else
              -- Nothing open on that socket, so start a datagram there. Any
              -- datagram open on a *different* socket is deliberately left
              -- alone -- that independence is the whole point of tracking this
              -- per socket, and is what lets interleaved traffic batch at all.
              if (ext_pl_tdata = x"56") then
                batch_solo(arriving_socket) <= '0';
              else
                batch_solo(arriving_socket) <= '1';
              end if;
              next_w5500_control_flow_state <= GET_TX_FREE_BUFFER_SIZE; -- here starts the TX sending data pipeline
            end if;
          elsif (idle_any = '1') then
            -- Nothing else is offered and some socket has had nothing for
            -- TX_FLUSH_IDLE_CLKS. Send what it holds rather than let it wait for
            -- companions that are not coming.
            current_socket_counter        <= idle_socket;
            next_w5500_control_flow_state <= UPDATE_TX_WRITE_POINTER_AFTER_WRITE;
          else
            next_w5500_control_flow_state <= GET_RX_SOCKET_RECEIVED_DATA_SIZE; -- if we can't send data now, we can check if we have received data
          end if;

        when GET_RX_SOCKET_RECEIVED_DATA_SIZE =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 2;
            spi_header_data           <= x"0026" & current_socket_counter & "01" & '0' & "00";
            spi_payload_data   <= x"00000000";
          end if;

          if (spi_transaction_finished = '1') then
            spi_payload_data_was_set <= '0';
            next_w5500_control_flow_state        <= WAIT_FOR_REQUESTED_RX_SOCKET_DATA_SIZE;
          end if;

        when WAIT_FOR_REQUESTED_RX_SOCKET_DATA_SIZE =>
          if (last_rx_packet_from_w5500_has_been_received = '1') then
            next_w5500_control_flow_state      <= CHECK_IF_RECEIVED_DATA_IS_AVAILABLE_STATE;
            rx_received_size_reg <= received_payload_buffer(11 downto 0);
          end if;

        when CHECK_IF_RECEIVED_DATA_IS_AVAILABLE_STATE =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then 
            if(rx_received_size_reg = "000000000000") then -- if nothing in the rx socket memory
              current_socket_counter <= std_logic_vector(unsigned(current_socket_counter) + 1);
              next_w5500_control_flow_state <= RETURN_TO_DEFAULT_ROUTINE;
            else
              next_w5500_control_flow_state <= GET_RX_READ_POINTER_STATE; -- else if we do have data, we can read it. We have to read as many bytes as rx_shift_payload_buffer(7 downto 0) is in size
              ext_pl_ruser <= current_socket_counter; -- show the ext_data_handler which socket the data is from
            end if;
          end if;

        when GET_RX_READ_POINTER_STATE =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 2;
            spi_header_data           <= x"0028" & current_socket_counter & "01" & '0' & "00";
            spi_payload_data   <= x"00000000";
          end if;

          if (spi_transaction_finished = '1') then
            spi_payload_data_was_set <= '0';
            next_w5500_control_flow_state <= WAIT_FOR_RX_READ_POINTER_TO_BE_RECEIVED;
          end if;

        when WAIT_FOR_RX_READ_POINTER_TO_BE_RECEIVED =>
          if (last_rx_packet_from_w5500_has_been_received = '1') then
            rx_pointer_reg                <= received_payload_buffer(15 downto 0);
            next_w5500_control_flow_state               <= READ_HEADER_AND_PAYLOAD_FROM_RX_BUFFER_STATE; -- if no data is received, then check again
            requested_streammanager_state <= "10"; -- this means RX_FIFO_PASSTHROUGH_MODE to the streammanager
          end if;

        when READ_HEADER_AND_PAYLOAD_FROM_RX_BUFFER_STATE =>
          -- reads the data from the Socket's RX Buffer
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= to_integer(unsigned(rx_received_size_reg));
            spi_header_data           <= rx_pointer_reg & current_socket_counter & "11" & '0' & "00";
            spi_payload_data   <= x"00000000";
          end if;

          if (spi_transaction_finished = '1') then
            spi_payload_data_was_set <= '0';
            next_w5500_control_flow_state <= WAIT_FOR_EXT_DATA_HANDLER_TO_FINISH_READING_FROM_FIFO;
          end if;

        when WAIT_FOR_EXT_DATA_HANDLER_TO_FINISH_READING_FROM_FIFO =>
          if (last_rx_packet_from_w5500_has_been_received = '1') then --if RX FIFO is empty, then all the contents have been read by the external data handler
            requested_streammanager_state <= "00"; -- this means Controller phase to the streammanager
            next_w5500_control_flow_state               <= UPDATE_RX_READ_POINTER_AFTER_BUFFER_READ;
            updated_rx_pointer_reg <= std_logic_vector(unsigned(rx_pointer_reg) + resize(unsigned(rx_received_size_reg), 16));
          end if;

        when UPDATE_RX_READ_POINTER_AFTER_BUFFER_READ =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 2;
            spi_header_data           <= x"0028" & current_socket_counter & "01" & '1' & "00";
            spi_payload_data   <= updated_rx_pointer_reg & x"0000";
          end if;

          if (spi_transaction_finished = '1') then
            spi_payload_data_was_set <= '0';
            next_w5500_control_flow_state <= ISSUE_READ_COMMAND_TO_UPDATE_RX_WRITE_POINTER;
          end if;
        
        when ISSUE_READ_COMMAND_TO_UPDATE_RX_WRITE_POINTER =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 1;
            spi_header_data           <= x"0001" & current_socket_counter & "01" & '1' & "00";
            spi_payload_data   <= x"40000000";
          end if;

          rx_pointer_reg            <= x"0000"; -- clean up 
          rx_received_size_reg      <= (others => '0');
          updated_rx_pointer_reg    <= (others => '0');

          if (spi_transaction_finished = '1') then
            spi_payload_data_was_set <= '0';
            next_w5500_control_flow_state <= RETURN_TO_DEFAULT_ROUTINE;
          end if;

          --^-- end of the RX Pipeline

          -- start of the TX Pipeline
        when GET_TX_FREE_BUFFER_SIZE =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 2;
            spi_header_data           <= x"0020" & current_socket_counter & "01" & '0' & "00";
            spi_payload_data   <= x"00000000";
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= CHECK_IF_FREE_SIZE_IS_AVAILABLE;
            spi_payload_data_was_set <= '0';
          end if;

        when CHECK_IF_FREE_SIZE_IS_AVAILABLE =>
          if (last_rx_packet_from_w5500_has_been_received = '1') then
            if (unsigned(received_payload_buffer(15 downto 0)) > minimum_free_tx_buffer_memory) then
              if (dest_regs_done(to_integer(unsigned(current_socket_counter))) = '1') then
                next_w5500_control_flow_state <= GET_TX_WRITE_POINTER; -- already programmed
              else
                next_w5500_control_flow_state <= SET_DESTINATION_IP_ADDRESS;
              end if;
            else
              next_w5500_control_flow_state <= GET_TX_FREE_BUFFER_SIZE;
            end if;
          end if;

        when SET_DESTINATION_IP_ADDRESS =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 4;
            spi_header_data           <= x"000C" & current_socket_counter & "01" & '1' & "00";
            spi_payload_data   <= dest_ip_address;
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= SET_DESTINATION_UDP_PORT;
            spi_payload_data_was_set <= '0';
          end if;

        when SET_DESTINATION_UDP_PORT =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 2;
            spi_header_data           <= x"0010" & current_socket_counter & "01" & '1' & "00";
            spi_payload_data   <= std_logic_vector(unsigned(dest_udp_port) + unsigned(current_socket_counter)) & x"0000";
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= GET_TX_WRITE_POINTER;
            spi_payload_data_was_set <= '0';
            dest_regs_done(to_integer(unsigned(current_socket_counter))) <= '1';
          end if;

        when GET_TX_WRITE_POINTER =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 2;
            spi_header_data           <= x"0024" & current_socket_counter & "01" & '0' & "00";
            spi_payload_data   <= x"00000000";
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= WAIT_FOR_TX_WRITE_POINTER_TO_BE_RECEIVED;
            spi_payload_data_was_set <= '0';
          end if;

        when WAIT_FOR_TX_WRITE_POINTER_TO_BE_RECEIVED =>
          if (last_rx_packet_from_w5500_has_been_received = '1') then
            next_w5500_control_flow_state <= WRITE_TX_DATA_TO_BUFFER;
            requested_streammanager_state <= "01"; --this means TX_FIFO_PASSTHROUGH_MODE to the stream manager
            -- Open this socket's datagram at the Sn_TX_WR just read back. From
            -- here tx_wr_cur walks forward over the whole datagram rather than
            -- being reset per packet, and the chip sees nothing until it is
            -- written back at the close.
            tx_wr_cur(tx_socket)     <= unsigned(received_payload_buffer(15 downto 0));
            batch_packets(tx_socket) <= 0;
            batch_open(tx_socket)    <= '1';
          end if;

        when WRITE_TX_DATA_TO_BUFFER =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            -- Append at this socket's running offset instead of the start of the
            -- buffer, so each packet lands behind the previous one and Sn_TX_WR
            -- is advanced once, at SEND, over the whole accumulated length.
            spi_header_data           <= std_logic_vector(tx_wr_cur(tx_socket)) & current_socket_counter & "10" & '1' & "00";
            spi_payload_data   <= x"00000000"; -- irrelevant as extenal source sets data
            spi_payload_data_byte_length   <= 1; -- same here
          end if;

          if (ptm_data_being_written_to_w5500 = '1') then
            tx_wr_cur(tx_socket) <= tx_wr_cur(tx_socket) + 1;
          end if;

          if (spi_transaction_finished = '1') then
            spi_payload_data_was_set <= '0';
            requested_streammanager_state <= "00";
            batch_packets(tx_socket) <= batch_packets(tx_socket) + 1;
            if (batch_packets(tx_socket) + 1 >= TX_BATCH_MAX_PACKETS
                or batch_solo(tx_socket) = '1') then
              next_w5500_control_flow_state <= UPDATE_TX_WRITE_POINTER_AFTER_WRITE;
            else
              -- Room left: go back and look for the next packet. This socket's
              -- datagram stays open, nothing has been sent yet.
              next_w5500_control_flow_state <= RETURN_TO_DEFAULT_ROUTINE;
            end if;
          end if;

        when UPDATE_TX_WRITE_POINTER_AFTER_WRITE =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 2;
            spi_header_data           <= x"0024" & current_socket_counter & "01" & '1' & "00";
            spi_payload_data   <= std_logic_vector(tx_wr_cur(tx_socket)) & x"0000";
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= ISSUE_SEND_COMMAND;
            spi_payload_data_was_set <= '0';
          end if;

        when ISSUE_SEND_COMMAND =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 1;
            spi_header_data           <= x"0001" & current_socket_counter & "01" & '1' & "00";
            spi_payload_data   <= x"20000000"; -- 0x20, send command
          end if;

          -- This socket's datagram is on its way out, so its accumulation state
          -- goes back to closed. Every other socket keeps whatever it holds.
          tx_wr_cur(tx_socket)     <= (others => '0');
          batch_packets(tx_socket) <= 0;
          batch_open(tx_socket)    <= '0';
          batch_solo(tx_socket)    <= '0';

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= GET_SOCKET_INTERRUPT_REGISTER;
            spi_payload_data_was_set <= '0';
          end if;


        when GET_SOCKET_INTERRUPT_REGISTER => -- page 46 on W5500 datasheet 
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 1;
            spi_header_data           <= x"0002" & current_socket_counter & "01" & '0' & "00";
            spi_payload_data   <= x"00000000";
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= WAIT_FOR_SOCKET_INTERRUPT_REGISTER_TO_BE_RECEIVED;
            spi_payload_data_was_set <= '0';
          end if;


        when WAIT_FOR_SOCKET_INTERRUPT_REGISTER_TO_BE_RECEIVED =>
          if (last_rx_packet_from_w5500_has_been_received = '1') then
            next_w5500_control_flow_state <= CHECK_SOCKET_INTERRUPT_REGISTER_RETURNED_VALUE; -- if no data is received, then check again
          end if;

        when CHECK_SOCKET_INTERRUPT_REGISTER_RETURNED_VALUE =>
          --page 48 of W5500 Datasheet
          if (received_payload_buffer(4) = '0') then -- check for the SEND_OK Bit in the Interrupt Register
            if (received_payload_buffer(3) = '1') then -- if the TIMEOUT Bit is set, then
              next_w5500_control_flow_state <= CLEAR_INTERRUPT_FLAGS_FROM_SOCKET_INTERRUPT_REGISTER;
            else
              next_w5500_control_flow_state <= GET_SOCKET_INTERRUPT_REGISTER; -- if the SEND_OK Bit and Timeout BIT aren't set, then transmission isn't done
            end if;

          else -- if SEND OK Bit is '1' then we can clear the interrupt flags and then go to the next package
            next_w5500_control_flow_state <= CLEAR_INTERRUPT_FLAGS_FROM_SOCKET_INTERRUPT_REGISTER;
          end if;

        when CLEAR_INTERRUPT_FLAGS_FROM_SOCKET_INTERRUPT_REGISTER =>
          if (prev_w5500_control_flow_state /= w5500_control_flow_state) then
            spi_payload_data_was_set <= '1';
            spi_payload_data_byte_length   <= 1;
            spi_header_data           <= x"0003" & current_socket_counter & "01" & '1' & "00";
            spi_payload_data   <= received_payload_buffer(7 downto 0) & x"000000";
          end if;

          if (spi_transaction_finished = '1') then
            next_w5500_control_flow_state <= RETURN_TO_DEFAULT_ROUTINE;
            spi_payload_data_was_set <= '0';
          end if;

        when others =>
      end case;

      -- Remember that the chip has been configured at least once, so the
      -- watchdog knows whether it may skip straight to the working loop.
      if w5500_control_flow_state = RETURN_TO_DEFAULT_ROUTINE then
        init_done <= '1';
      end if;

      -- Watchdog escape. Assigned after the case so it overrides whatever the
      -- current state decided, and it clears everything that could be left half
      -- open: the stream manager goes back to controller phase, any accumulating
      -- datagram is abandoned rather than sent with a length nobody can trust.
      if watchdog >= WATCHDOG_CLKS then
        requested_streammanager_state <= "00";
        spi_payload_data_was_set      <= '0';
        batch_open                    <= (others => '0');
        batch_solo                    <= (others => '0');
        batch_packets                 <= (others => 0);
        tx_wr_cur                     <= (others => (others => '0'));
        if init_done = '1' then
          next_w5500_control_flow_state <= RETURN_TO_DEFAULT_ROUTINE;
        else
          next_w5500_control_flow_state <= RESET_STATE;
        end if;
      end if;

      prev_spi_busy <= spi_busy;

      --- end of the W5500 finite state machine ----
    end if;
  end process;

  --- SPI DATA Streamer AXI stream manager ---
  -- Switches control of PAYLOAD FIFO in the W5500 Data streamer. TX/RX Passthrough phase or controller phase

  u_w5500_stream_manager : w5500_stream_manager
  port map
  (
    clk                                         => clk,
    reset                                       => reset,
    requested_streammanager_state               => requested_streammanager_state,
    ext_pl_tdata                                => ext_pl_tdata,
    ext_pl_tvalid                               => ext_pl_tvalid,
    ext_pl_tready                               => ext_pl_tready_int,
    ext_pl_tlast                                => ext_pl_tlast,
    ext_pl_rdata                                => ext_pl_rdata,
    ext_pl_rvalid                               => ext_pl_rvalid,
    ext_pl_rlast                                => ext_pl_rlast,
    ext_pl_rready                               => ext_pl_rready,
    tx_payload_data                             => tx_payload_data,
    tx_payload_ready                            => tx_payload_ready,
    tx_payload_valid                            => tx_payload_valid,
    tx_payload_last                             => tx_payload_last,
    rx_payload_data                             => rx_payload_data,
    rx_payload_valid                            => rx_payload_valid,
    rx_payload_ready                            => rx_payload_ready,
    rx_payload_last                             => rx_payload_last,
    received_payload_buffer                     => received_payload_buffer,
    spi_header_data                             => spi_header_data,
    spi_header_valid                            => spi_header_valid,
    spi_data_buffer                             => spi_payload_data,
    spi_data_length                             => spi_payload_data_byte_length,
    payload_data_has_been_set                   => spi_payload_data_was_set,
    ptm_data_being_written_to_w5500             => ptm_data_being_written_to_w5500,
    last_rx_packet_from_w5500_has_been_received => last_rx_packet_from_w5500_has_been_received
  );
end architecture behavioral;
