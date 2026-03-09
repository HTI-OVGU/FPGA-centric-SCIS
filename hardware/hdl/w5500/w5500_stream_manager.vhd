-- This stream manager handles data streams to and from the external data handler, streams coming to and from the FSM, such as streams going towards and coming from the spi data streamer.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity w5500_stream_manager is
  port (
    clk         : in std_logic;
    reset       : in std_logic;

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

    received_payload_buffer : out std_logic_vector(31 downto 0); --4*8 bit buffer, that can store up to 4 Bytes of data simultaneously, coming from the W5500

    spi_header_data : in std_logic_vector(23 downto 0); -- SPI Header data from the FSM
    spi_header_valid : out std_logic;

    spi_data_buffer : in std_logic_vector(31 downto 0); -- raw spi payload data from FSM
    spi_data_length : in integer range 0 to 2047; -- amount of payload bytes to be transmitted
    payload_data_has_been_set : in std_logic;

    ptm_data_being_written_to_w5500 : out std_logic;
    last_rx_packet_from_w5500_has_been_received : out std_logic -- sticky latch, that stays high until the next transmission towards the w5500 startslast_rx_packet_from_w5500_has_been_received

  );
end w5500_stream_manager;

architecture Behavioral of w5500_stream_manager is

-- spi streamer axi streamer state

type fifo_data_stream_handler_state_type is (CONTROLLER_PHASE, TX_FIFO_PASSTHROUGH_MODE, RX_FIFO_PASSTHROUGH_MODE);
signal streammanager_state: fifo_data_stream_handler_state_type;

type udp_packet_separator_state_type is (UDP_HEADER_PHASE, UDP_PAYLOAD_PHASE);
signal udp_packet_separator_state, udp_packet_separator_next_state : udp_packet_separator_state_type := UDP_HEADER_PHASE;

signal prev_payload_data_has_been_set : std_logic := '0';

signal rx_shift_payload_buffer : std_logic_vector(31 downto 0) := (others => '0'); --4*8 bit buffer, that can store up to 4 Bytes of data simultaneously, coming from the W5500
signal tx_shift_payload_buffer : std_logic_vector(31 downto 0) := (others => '0'); --4*8 bit buffer, storing the payload data coming from the W5500 FSM, that's supposed to go to the W5500

signal pl_byte_length_buffer : integer range 0 to 2047 := 0;

signal ptm_packet_done : std_logic := '0';

signal int_ext_pl_tready : std_logic := '0';

signal udp_packet_seperator_tlast : std_logic := '0';
signal udp_header_counter : integer := 0;
signal udp_header_payload_length_buffer : STD_LOGIC_VECTOR(15 downto 0) := x"0000";
signal current_udp_payload_counter : integer := 0;



begin

received_payload_buffer <= rx_shift_payload_buffer; -- whatever has been received (pointers, free buffer size, ...) should be passed to the FSM
ext_pl_tready <= int_ext_pl_tready;

process(clk) -- W5500 FSM requests the streammanager state
begin
    if(rising_edge(clk)) then
        if(reset = '1') then
            streammanager_state <= CONTROLLER_PHASE;
        else
            case requested_streammanager_state is
                when "00" => streammanager_state <= CONTROLLER_PHASE;
                when "01" => streammanager_state <= TX_FIFO_PASSTHROUGH_MODE;
                when others => streammanager_state <= RX_FIFO_PASSTHROUGH_MODE;
            end case;
        end if;
    end if;
end process;

 --combinatorical process

process(streammanager_state, ptm_packet_done, ext_pl_tvalid, tx_payload_ready, rx_payload_valid, ext_pl_rready)
begin
    --defaults
    ptm_data_being_written_to_w5500 <= '0';
    int_ext_pl_tready <= '0';

    case streammanager_state is

    when TX_FIFO_PASSTHROUGH_MODE =>
        if ptm_packet_done = '1' then
            -- Stream is cut off after tlast
            ptm_data_being_written_to_w5500 <= '0';
            int_ext_pl_tready <= '0';
        else
            -- Normal passthrough
            int_ext_pl_tready <= tx_payload_ready;
            if ext_pl_tvalid = '1' and tx_payload_ready = '1' then
                ptm_data_being_written_to_w5500 <= '1';
            else
                ptm_data_being_written_to_w5500 <= '0';
            end if;
        end if;

        rx_payload_ready <= '1';
        ext_pl_rvalid <= '0';
        ext_pl_rlast <= '0';
        ext_pl_rdata <= x"00";

    when RX_FIFO_PASSTHROUGH_MODE =>
        int_ext_pl_tready <= '0';
        ptm_data_being_written_to_w5500 <= '0';

        rx_payload_ready <= ext_pl_rready;
        ext_pl_rvalid <= rx_payload_valid;
        ext_pl_rdata  <= rx_payload_data;
        ext_pl_rlast  <= rx_payload_last or udp_packet_seperator_tlast;

    when CONTROLLER_PHASE =>

        rx_payload_ready <= '1';
        ext_pl_rvalid <= '0';
        ext_pl_rlast <= '0';
        ext_pl_rdata <= x"00";

        int_ext_pl_tready <= '0';
        ptm_data_being_written_to_w5500 <= '0';
    end case;
end process;

--detect last packet from ext_pl_tdata axi stream
process(clk, reset)
begin
    if rising_edge(clk) then
        if reset = '1' then
            ptm_packet_done <= '0';
        else
            case streammanager_state is
                when TX_FIFO_PASSTHROUGH_MODE =>
                    -- Detect when last data is successfully transferred
                    if ext_pl_tvalid = '1' and int_ext_pl_tready = '1' and ext_pl_tlast = '1' then
                        ptm_packet_done <= '1';
                    end if;
                when others =>
                    ptm_packet_done <= '0'; -- Reset when not in tx passthrough mode
            end case;
        end if;
    end if;
end process;

process (clk, reset)
begin
    if rising_edge(clk) then
        if(reset = '1') then
            tx_payload_valid       <= '0';
            tx_payload_last        <= '0';
            tx_payload_data <= x"00";
            rx_shift_payload_buffer <= x"00000000";
            tx_shift_payload_buffer <= x"00000000";
            prev_payload_data_has_been_set <= '0';
            spi_header_valid <= '0';
        else 
            prev_payload_data_has_been_set <= payload_data_has_been_set;

            if streammanager_state = TX_FIFO_PASSTHROUGH_MODE then
                if(ptm_packet_done = '1') then
                    tx_payload_data <= x"00";
                    tx_payload_last <= '0';
                    tx_payload_valid <= '0';
                    spi_header_valid <= '0';
                else
                    tx_payload_data <= ext_pl_tdata;
                    tx_payload_last <= ext_pl_tlast;
                    tx_payload_valid <= ext_pl_tvalid;
                end if;

                if ext_pl_tvalid = '1' then
                    spi_header_valid <= '1';
                else
                    spi_header_valid <= '0';
                end if;

                last_rx_packet_from_w5500_has_been_received <= '0';

            elsif streammanager_state = CONTROLLER_PHASE then
                if (pl_byte_length_buffer > 0) then
                    tx_payload_data  <= tx_shift_payload_buffer(31 downto 24);
                    tx_shift_payload_buffer <= tx_shift_payload_buffer(23 downto 0) & "00000000";
                    pl_byte_length_buffer   <= pl_byte_length_buffer - 1;
                    last_rx_packet_from_w5500_has_been_received <= '0';
                    tx_payload_valid <= '1';
                    spi_header_valid <= '1';

                    if (pl_byte_length_buffer = 1) then
                        tx_payload_last <= '1';
                    else
                        tx_payload_last <= '0';
                    end if;
                else
                    tx_payload_valid <= '0';
                    tx_payload_last  <= '0';
                    spi_header_valid <= '0';
                end if;

                if (prev_payload_data_has_been_set = '0' and payload_data_has_been_set = '1') then
                    pl_byte_length_buffer <= spi_data_length;
                    tx_shift_payload_buffer <= spi_data_buffer;
                    last_rx_packet_from_w5500_has_been_received <= '0';
                end if;


                if (rx_payload_valid = '1') then
                    rx_shift_payload_buffer <= rx_shift_payload_buffer(23 downto 0) & rx_payload_data;
                end if;

                if(rx_payload_last = '1' and rx_payload_valid = '1') then
                    last_rx_packet_from_w5500_has_been_received <= '1';
                end if;

            elsif streammanager_state = RX_FIFO_PASSTHROUGH_MODE then
                
                if (pl_byte_length_buffer > 0) then
                    pl_byte_length_buffer <= pl_byte_length_buffer - 1;
                    tx_payload_valid <= '1';
                    spi_header_valid <= '1';

                    if (pl_byte_length_buffer = 1) then
                        tx_payload_last <= '1';
                    else
                        tx_payload_last <= '0';
                    end if;
                else
                    tx_payload_valid <= '0';
                    tx_payload_last  <= '0';
                    spi_header_valid <= '0';
                end if;

                if (prev_payload_data_has_been_set = '0' and payload_data_has_been_set = '1') then
                    pl_byte_length_buffer <= spi_data_length;
                    last_rx_packet_from_w5500_has_been_received <= '0';
                end if;

                if(rx_payload_last = '1' and rx_payload_valid = '1' and ext_pl_rready = '1') then
                    last_rx_packet_from_w5500_has_been_received <= '1';
                end if;
            else
                tx_payload_valid <= '0';
                tx_payload_last  <= '0';
            end if;
        end if;
    end if;

end process;


-- this is W5500 specific code, because when multiple UDP packets are in RX Socket Memory, only the entirety of the RX Memory can be read
-- seperation of these packets has to be done by parsing the UDP Header first, this separation cannot be done on W5500


process(clk, reset )
begin 
    if(rising_edge(clk)) then 
        if(reset = '1') then 
            udp_packet_separator_state <= UDP_HEADER_PHASE;
        else 
            udp_packet_separator_state <= udp_packet_separator_next_state;
        end if;
    end if;
end process;

process (clk, reset)  
begin 
    if(rising_edge(clk)) then
        if(reset = '1') then
            udp_packet_seperator_tlast <= '0';
            udp_header_counter <= 0;
            udp_packet_separator_next_state <= UDP_HEADER_PHASE;
        else 
            
            case streammanager_state is
            when RX_FIFO_PASSTHROUGH_MODE =>
                case udp_packet_separator_state is  
                    when UDP_HEADER_PHASE =>
                        udp_packet_seperator_tlast <= '0';

                        if(rx_payload_valid = '1' and ext_pl_rready = '1') then 
                            udp_header_counter <= udp_header_counter + 1;
                        end if;

                        if(udp_header_counter = 6) then 
                            udp_header_payload_length_buffer(15 downto 8) <= rx_payload_data;
                        end if;

                        if(udp_header_counter = 7) then 
                            udp_header_payload_length_buffer(7 downto 0) <= rx_payload_data;
                        end if;

                        if(udp_header_counter = 8) then 
                            current_udp_payload_counter <= to_integer(unsigned(udp_header_payload_length_buffer));
                            udp_packet_separator_next_state <= UDP_PAYLOAD_PHASE;
                        end if;

                    when UDP_PAYLOAD_PHASE =>
                        if(current_udp_payload_counter > 0) then

                            if(rx_payload_valid = '1' and ext_pl_rready = '1') then 
                                current_udp_payload_counter <= current_udp_payload_counter - 1;
                            end if;

                            if(current_udp_payload_counter = 1) then 
                                udp_packet_seperator_tlast <= '1';
                            else 
                                udp_packet_seperator_tlast <= '0';
                            end if;
                        else
                            
                            udp_packet_separator_next_state <= UDP_HEADER_PHASE;
                            current_udp_payload_counter <= 0;
                            udp_header_counter <= 0;
                        end if;

                end case;
                
            when others  =>
                udp_header_counter <= 0;
                current_udp_payload_counter <= 0;
                udp_packet_separator_next_state <= UDP_HEADER_PHASE;

            end case;

        end if;

    end if;

end process;

end Behavioral;
