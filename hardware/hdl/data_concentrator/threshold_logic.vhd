library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.metric_axi_stream_pkg.all;

entity threshold_logic is
    port (
        clk         : in  STD_LOGIC;
        reset       : in  STD_LOGIC;
        tdata       : out STD_LOGIC_VECTOR(7 downto 0);
        tvalid      : out STD_LOGIC;
        tlast       : out STD_LOGIC;
        tready      : in  STD_LOGIC;
        tuser       : out STD_LOGIC_VECTOR(2 downto 0);
        rdata       : in  STD_LOGIC_VECTOR(7 downto 0);
        rlast       : in  STD_LOGIC;
        rvalid      : in  STD_LOGIC;
        rready      : out STD_LOGIC;
        ruser       : in  STD_LOGIC_VECTOR(2 downto 0);
        interlock  : out STD_LOGIC;
        deassert_interlock : in STD_LOGIC

    );
end threshold_logic;

architecture Behavioral of threshold_logic is

type thresholding_state_type is (IDLE, RECEIVE_METRIC_PACKET_HEADER, RECEIVE_QMN_FIXED_POINT_VALUE_AND_LOOKUP_FROM_BRAM, CHECK_THRESHOLDS, PASSTHROUGH);
signal current_thresholding_state : thresholding_state_type := IDLE;

signal current_metric_packet_header_receive_counter : integer := 0;
signal metric_protocol_version : std_logic_vector(23 downto 0) := (others => '0');
signal metric_device_id : std_logic_vector(15 downto 0) := (others => '0');
signal metric_value : std_logic_vector(31 downto 0) := x"00000000";

signal int_data : std_logic_vector(7 downto 0);
signal int_user : std_logic_vector(2 downto 0);
signal int_valid : std_logic;
signal int_ready : std_logic;
signal int_last : std_logic;

-- Dual Port RAM (WRITE_THROUGH) -- LOOKUP BRAM
component threshold_lookup_bram is
  generic (
    DATA_WIDTH : integer := 32;
    ADDR_WIDTH : integer := 10
  );
  port (
    wea   : in std_logic;
    web   : in std_logic;
    clka  : in std_logic;
    clkb  : in std_logic;
    dia   : in std_logic_vector(DATA_WIDTH - 1 downto 0);
    dib   : in std_logic_vector(DATA_WIDTH - 1 downto 0);
    addra : in std_logic_vector(ADDR_WIDTH - 1 downto 0);
    addrb : in std_logic_vector(ADDR_WIDTH - 1 downto 0);
    doa   : out std_logic_vector(DATA_WIDTH - 1 downto 0);
    dob   : out std_logic_vector(DATA_WIDTH - 1 downto 0)
  );
end component;

component metric_packet_fifo is
        generic (
            g_WIDTH : natural := 20;
            g_DEPTH : natural := 1023
        );
        port (
            i_clk          : in  std_logic;
            i_rst_sync     : in  std_logic; -- Active-High Synchronous Reset

            -- AXI Stream Slave Interface (Write Side)
            s_axis_tvalid  : in  std_logic;
            s_axis_tdata   : in  std_logic_vector(7 downto 0);
            s_axis_tlast   : in  std_logic;
            s_axis_tready  : out std_logic;
            s_axis_tuser   : in  std_logic_vector(2 downto 0);

            -- AXI Stream Master Interface (Read Side)
            m_axis_tvalid  : out std_logic;
            m_axis_tdata   : out std_logic_vector(7 downto 0);
            m_axis_tlast   : out std_logic;
            m_axis_tready  : in  std_logic;
            m_axis_tuser   : out STD_LOGIC_VECTOR(2 downto 0)
        ); 
    end component;

signal decoded_lower_threshold_address : std_logic_vector(10 downto 0);
signal decoded_upper_threshold_address : std_logic_vector(10 downto 0);

signal doa_reg : std_logic_vector(31 downto 0);
signal dob_reg : std_logic_vector(31 downto 0);

signal lower_threshold : signed(31 downto 0);
signal upper_threshold : signed(31 downto 0);

signal packet_read_by_threshold_logic : std_logic := '0';
signal int_interlock : std_logic := '0';


begin

  -- in here, the stream is first parsed (metric header + 32 fixed point value QM.N),
  -- then the threshold(s) are looked up in BRAM, 
  -- then an interlock signal is asserted if necessary  

        int_valid <= rvalid;
        int_user <= ruser;
        int_data <= rdata;
        int_last <= rlast;

        interlock <= int_interlock;

    -- general FSM of thresholding logic block
    process (reset, clk) 
    begin 

    if(rising_edge(clk)) then 
        if(reset = '1') then 
            current_thresholding_state <= IDLE;
            int_interlock <= '0';
        else 
            case current_thresholding_state is 
                when IDLE =>
                --report "IDLING";
                    if(int_valid = '1' and int_ready = '1') then  
                        current_thresholding_state <= RECEIVE_METRIC_PACKET_HEADER;
                        -- this successful AXI Stream handshake accepts the "V" from the protocol code
                        metric_protocol_version <= metric_protocol_version(15 downto 0) & rdata;
                    end if;

                when RECEIVE_METRIC_PACKET_HEADER =>
                    if(int_valid = '1' and int_ready = '1') then
                        if(current_metric_packet_header_receive_counter < 3) then  -- protocol version (0,1,2)
                            metric_protocol_version <= metric_protocol_version(15 downto 0) & rdata;
                        elsif (current_metric_packet_header_receive_counter < 5) then -- device identifier (3,4)
                            metric_device_id <= metric_device_id(7 downto 0) & rdata;
                            if(current_metric_packet_header_receive_counter = 4) then
                                if(metric_protocol_version = x"563031") then -- if protocol code is "V01"
                                    current_thresholding_state <= RECEIVE_QMN_FIXED_POINT_VALUE_AND_LOOKUP_FROM_BRAM;
                                else 
                                    current_thresholding_state <= PASSTHROUGH;
                                end if;
                            end if;
                        end if;
                    end if;
                    
                when RECEIVE_QMN_FIXED_POINT_VALUE_AND_LOOKUP_FROM_BRAM =>
                    -- receives the metric value on axi stream bus
                    if(int_valid = '1' and int_ready = '1') then
                        metric_value <= metric_value(23 downto 0) & rdata;
                    end if;

                    if(int_last = '1' and int_valid = '1' and int_ready = '1') then 
                        --report "last received";
                        current_thresholding_state <= CHECK_THRESHOLDS;
                    end if;

                    decoded_lower_threshold_address <= metric_device_id(15 downto 6) & '0';
                    decoded_upper_threshold_address <= metric_device_id(15 downto 6) & '1';
                    

                when CHECK_THRESHOLDS =>
                    --report "comparing thresholds";
                    
                    if(signed(metric_value) < lower_threshold) or (signed(metric_value) > upper_threshold)  then 
                        int_interlock <= '1';
                    end if;

                    current_thresholding_state <= IDLE;

                when PASSTHROUGH =>
                    if(int_last = '1' and int_valid = '1' and int_ready = '1') then 
                        current_thresholding_state <= IDLE;
                    end if;

            end case;

            if(deassert_interlock = '1') then  
                int_interlock <= '0';
            end if;

        end if;
    end if;
    end process;

    process(clk, reset)
    begin 
        if rising_edge(clk) then
            if(reset = '1') then 
                current_metric_packet_header_receive_counter <= 0;
            else 
                if(current_thresholding_state = CHECK_THRESHOLDS) then 
                    current_metric_packet_header_receive_counter <= 0;
                else 
                    if(int_valid = '1' and int_ready = '1') then
                        if(int_last = '1') then
                            current_metric_packet_header_receive_counter <= 0;
                        else
                            current_metric_packet_header_receive_counter <= current_metric_packet_header_receive_counter + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    
    end process;


    lookup_bram : threshold_lookup_bram
     generic map(
        DATA_WIDTH => 32,
        ADDR_WIDTH => 11 -- 10 bit per device + 1 such that 2 BRAMs are generated
    )
     port map(
        wea => '0',
        web => '0',
        clka => clk,
        clkb => clk,
        dia => (others => '0'),
        dib => (others => '0'),
        addra => decoded_lower_threshold_address, -- fetches lower threshold
        addrb => decoded_upper_threshold_address, -- fetches upper threshold
        doa => doa_reg, -- lower threshold
        dob => dob_reg -- upper threshold
    );

    lower_threshold <= signed(doa_reg(31 downto 0));
    upper_threshold <= signed(dob_reg(31 downto 0));

    rready <= int_ready;

    buffer_fifo : metric_packet_fifo
     generic map(
        g_WIDTH => 20,
        g_DEPTH => 1023
    )
     port map(
        i_clk => clk,
        i_rst_sync => reset,
        s_axis_tvalid => int_valid, 
        s_axis_tdata => int_data,
        s_axis_tlast => int_last,
        s_axis_tready => int_ready,
        s_axis_tuser => int_user,

        m_axis_tvalid => tvalid,
        m_axis_tdata => tdata,
        m_axis_tlast => tlast,
        m_axis_tready => tready,
        m_axis_tuser => tuser
    );

end Behavioral;