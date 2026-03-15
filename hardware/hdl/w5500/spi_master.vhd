----------------------------------------------------------------------------------
-- File: spi_master.vhd
-- Description: SPI Master Transceive Unit
-- Supports continuous byte-by-byte transmission from FIFO
-- Tracks transmission until tlast signal
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity spi_master is
    port (
        tdata:   in std_logic_vector (7 downto 0);
        rdata:   out std_logic_vector (7 downto 0);
        mosi:    out std_logic;
        miso:    in std_logic := '0';
        sclk:    out std_logic;
        cs:      out std_logic := '1';
        clk:     in std_logic;
        reset:   in std_logic := '0';
        spi_busy: out std_logic;
        tvalid:  in std_logic;
        tready:  out std_logic;
        tlast:   in std_logic := '0';
        rvalid:  out std_logic;
        rready:  in std_logic := '0';
        rlast:   out std_logic := '0'
    );
end entity spi_master;

architecture behavioral of spi_master is
    -- Retain original state type
    type spi_state is (wait_for_fifo_ready, spi_idle, spi_execute, spi_done);
    signal spistate, spistate_next: spi_state;

    -- Core signals maintained from original design
    signal clk_toggles : integer := 0;
    signal sclk_buffer : std_logic;
    signal tx_phase : std_logic;

    signal cs_buffer : std_logic := '1';
    signal rdata_buffer : std_logic_vector(7 downto 0);
    signal tx_buffer : std_logic_vector(7 downto 0) := (others=>'0');

    -- Transmission tracking signals
    signal tx_payload_data : std_logic_vector(7 downto 0) := (others=>'0');
    signal tx_payload_valid : std_logic := '0';
    signal tx_payload_valid_buffer : std_logic := '0';
    signal tx_payload_ready : std_logic := '0';
    signal tx_payload_last : std_logic := '0';

    -- Reception tracking signals
    signal rx_buffer_data :  std_logic_vector(7 downto 0) := (others=>'0');
    signal rx_buffer_valid : std_logic := '0';
    signal rx_buffer_ready : std_logic := '1';
    signal rx_buffer_last : std_logic := '0';

    signal tready_int_buffer : std_logic := '0';
    signal rvalid_buffer : std_logic := '0';
    signal rlast_buffer : std_logic := '0';

    signal first_execute : std_logic := '1';
    signal last_byte_of_spi_transaction : std_logic := '0';

    component axis_data_fifo is
        generic (
            g_WIDTH : natural := 10;
            g_DEPTH : natural := 2047
        );
        port(
            s_axis_tdata : in std_logic_vector(7 downto 0);
            s_axis_tready: out std_logic;
            s_axis_tvalid : in std_logic;
            i_clk : in std_logic;
            s_axis_tlast : in std_logic;
            i_rst_sync : in std_logic;
            m_axis_tdata : out std_logic_vector(7 downto 0);
            m_axis_tready: in std_logic;
            m_axis_tvalid : out std_logic;
            m_axis_tlast : out std_logic
        );
    end component;

begin
    -- Output signal assignments
    cs <= cs_buffer;
    sclk <= sclk_buffer;

    -- TX Payload FIFO: Stores data to be sent
    u_tx_payload_fifo : axis_data_fifo
        generic map(
            g_WIDTH => 10,
            g_DEPTH => 2047
        )
        port map (
            s_axis_tdata => tdata,
            s_axis_tready => tready_int_buffer,
            s_axis_tvalid => tvalid,
            s_axis_tlast => tlast,
            i_clk => clk,
            i_rst_sync => reset,
            m_axis_tdata => tx_payload_data,
            m_axis_tready => tx_payload_ready,
            m_axis_tvalid => tx_payload_valid,
            m_axis_tlast => tx_payload_last
        );

    tready <= tready_int_buffer;
    tx_payload_valid_buffer <= tx_payload_valid;

    -- RX Payload FIFO: Stores received data
    u_rx_payload_fifo : axis_data_fifo
        generic map(
            g_WIDTH => 10,
            g_DEPTH => 2047
        )
        port map (
            s_axis_tdata => rx_buffer_data,
            s_axis_tready => rx_buffer_ready,
            s_axis_tvalid => rx_buffer_valid,
            s_axis_tlast => rx_buffer_last,
            i_clk => clk,
            i_rst_sync => reset,
            m_axis_tdata => rdata_buffer,
            m_axis_tready => rready,
            m_axis_tvalid => rvalid_buffer,
            m_axis_tlast => rlast_buffer
        );

    rdata <= rdata_buffer;
    rvalid <= rvalid_buffer;
    rlast <= rlast_buffer;

    -- State Memory Process
    state_memory: process (clk, reset)
    begin
        
        if (rising_edge(clk)) then
            if(reset = '1') then
                spistate <= spi_idle;
            else
                spistate <= spistate_next;
            end if;
        end if;
    end process;

    -- Main State Machine Process
    state_machine: process (clk, reset, spistate)
    begin
        if rising_edge(clk) then
            if(reset = '1') then
                spi_busy <= '0';
                cs_buffer <= '1';
                tx_phase <= '0';
                spistate_next <= wait_for_fifo_ready;
                last_byte_of_spi_transaction <= '0';
            else
                case spistate is
                when wait_for_fifo_ready =>
                    cs_buffer <= '1';
                    spi_busy <= '0';
                    tx_phase <= '0';
                    last_byte_of_spi_transaction <= '0';

                    if tready_int_buffer = '1' then
                        spistate_next <= spi_idle;
                    else
                        spistate_next <= wait_for_fifo_ready;
                    end if;

                when spi_idle =>
                    cs_buffer <= '1';
                    spi_busy <= '0';
                    tx_phase <= '0';

                    if tx_payload_valid_buffer = '1' then
                        spistate_next <= spi_execute;

                        if(tx_payload_last = '1') then 
                            last_byte_of_spi_transaction <= '1';
                        else 
                            last_byte_of_spi_transaction <= '0'; 
                        end if;
                    else
                        spistate_next <= spi_idle;
                    end if;

                    if(spistate_next = spi_execute) then
                        tx_buffer <= tx_payload_data;
                        tx_payload_ready <= '1';
                        first_execute <= '1';
                    end if;

                when spi_execute =>
                    tx_payload_ready <= '0';
                    cs_buffer <= '0';
                    spi_busy <= '1';
                    
                    -- Transmit data
                    if(clk_toggles mod 2 = 1) then -- falling edge of sclk
                        tx_buffer <= tx_buffer(8-2 downto 0) & '0';
                    end if;

                    if(clk_toggles = 15 and last_byte_of_spi_transaction = '0') then 
                        tx_payload_ready <= '1';
                        tx_buffer <= tx_payload_data;
                        last_byte_of_spi_transaction <= tx_payload_last;
                    else
                        tx_payload_ready <= '0';
                    end if;


                    -- Receive data
                    if(clk_toggles mod 2 = 0) then -- rising edge of sclk
                        if(clk_toggles = 0 and first_execute = '1') then --for when the Transmission just started, the very first tx_phase 1 is skipped as the W5500 does not start writing yet
                            rx_buffer_data <= rx_buffer_data; --leave the rx buffer for transmission start, nothing to read on MISO yet 
                        else
                            rx_buffer_data <= rx_buffer_data(8-2 downto 0) & miso; --read MISO into rx_buffer_data  
                        end if;        
                    end if;

                    if(clk_toggles = 15) then
                        rx_buffer_valid <= '1';
                    else
                        rx_buffer_valid <= '0';
                    end if;

                    if(tx_payload_valid_buffer = '0') then --if no more bytes to send, then also no more bytes to receive -> last byte
                        rx_buffer_last <= '1';
                    else
                        rx_buffer_last <= '0';
                    end if;

                    -- Transaction completion logic
                    if(clk_toggles = 15) then
                         if(last_byte_of_spi_transaction = '1') then
                            spistate_next <= spi_done;
                         else
                            spistate_next <= spi_execute;
                            first_execute <= '0';
                         end if;
                    else
                        if(spistate_next /= spi_done) then
                            spistate_next <= spi_execute;
                        end if;
                    end if;

                when spi_done =>
                    tx_payload_ready <= '0';
                    spistate_next <= spi_idle;

                when others =>
                    spistate_next <= spi_idle;
            end case;
        end if;
    end if;
    end process;

    process (clk, reset) -- sclk process
    begin 
        if(rising_edge(clk)) then 
            if(reset = '1') then 
                sclk_buffer <= '0';
                clk_toggles <= 0;
            else 
                if(cs_buffer = '0' and spistate = spi_execute) then 
                    sclk_buffer <= not sclk_buffer;
                    if(clk_toggles < 15) then
                        clk_toggles <= clk_toggles + 1;
                    else 
                        clk_toggles <= 0;
                    end if;
                else 
                    sclk_buffer <= '0';
                    clk_toggles <= 0;
                end if;
            end if;

        end if;
    end process;

    process (clk, reset, tx_buffer) -- mosi_writer
    begin 
    
        if(reset = '1') then 
            mosi <= '0';
        else 
            if(spistate = spi_execute) then
                mosi <= tx_buffer(7);
            elsif spistate = spi_done then
                mosi <= 'Z';
            else 
                mosi <= '0';
            end if;
        end if;
    end process;


end architecture behavioral;
