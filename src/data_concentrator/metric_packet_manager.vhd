library ieee;
use ieee.std_logic_1164.all;
use IEEE.NUMERIC_STD.ALL;
use work.metric_axi_stream_pkg.all;

entity metric_packet_manager is
    generic (
        metric_input_stream_amount : INTEGER := 1
    );
    port (
        clk   : in std_logic;
        reset : in std_logic;
        s_axis: in metric_axi_stream_array_t(0 to metric_input_stream_amount-1); -- these are the metric packet streams coming in
        s_axis_tready : out std_logic_vector(0 downto metric_input_stream_amount-1);
        m_axis : out metric_axi_stream_t; -- towards the thresholding mechanism
        m_axis_tready : in std_logic;
        almost_full_vector : out std_logic_vector(7 downto 0)
        );

end entity;

architecture Behavioral of metric_packet_manager is

    component priority_axis_data_fifo is
        generic (
            g_WIDTH : natural := 10;
            g_DEPTH : natural := 2047
        );
        port (
            i_clk          : in  std_logic;
            i_rst_sync     : in  std_logic; -- Active-High Synchronous Reset

            -- AXI Stream Slave Interface (Write Side)
            s_axis_tvalid  : in  std_logic;
            s_axis_tdata   : in  std_logic_vector(7 downto 0);
            s_axis_tlast   : in  std_logic;
            s_axis_tready  : out std_logic;

            -- AXI Stream Master Interface (Read Side)
            m_axis_tvalid  : out std_logic;
            m_axis_tdata   : out std_logic_vector(7 downto 0);
            m_axis_tlast   : out std_logic;
            m_axis_tready  : in  std_logic;
            almost_full    : out std_logic
            
        ); 
    end component;

    type packet_manager_state is (ROUND_ROBIN, PASSTHROUGH);
    signal current_input_arbiter_state, next_input_arbiter_state : packet_manager_state := ROUND_ROBIN;

    type priority_arbiter_state is (CHECK_AVAILABLE_FIFO_DATA, PASSTHROUGH_TO_OUTPUT);
    signal current_output_arbiter_state : priority_arbiter_state := CHECK_AVAILABLE_FIFO_DATA;

    signal s_axis_fifo_0 : metric_axi_stream_t;
    signal s_axis_fifo_1 : metric_axi_stream_t;
    signal s_axis_fifo_2 : metric_axi_stream_t;
    signal s_axis_fifo_3 : metric_axi_stream_t;
    signal s_axis_fifo_4 : metric_axi_stream_t;
    signal s_axis_fifo_5 : metric_axi_stream_t;
    signal s_axis_fifo_6 : metric_axi_stream_t;
    signal s_axis_fifo_7 : metric_axi_stream_t;
    signal s_axis_fifo_0_tready : std_logic;
    signal s_axis_fifo_1_tready : std_logic;
    signal s_axis_fifo_2_tready : std_logic;
    signal s_axis_fifo_3_tready : std_logic;
    signal s_axis_fifo_4_tready : std_logic;
    signal s_axis_fifo_5_tready : std_logic;
    signal s_axis_fifo_6_tready : std_logic;
    signal s_axis_fifo_7_tready : std_logic;

    signal m_axis_fifo_0 : metric_axi_stream_t;
    signal m_axis_fifo_1 : metric_axi_stream_t;
    signal m_axis_fifo_2 : metric_axi_stream_t;
    signal m_axis_fifo_3 : metric_axi_stream_t;
    signal m_axis_fifo_4 : metric_axi_stream_t;
    signal m_axis_fifo_5 : metric_axi_stream_t;
    signal m_axis_fifo_6 : metric_axi_stream_t;
    signal m_axis_fifo_7 : metric_axi_stream_t;
    signal m_axis_fifo_0_tready : std_logic;
    signal m_axis_fifo_1_tready : std_logic;
    signal m_axis_fifo_2_tready : std_logic;
    signal m_axis_fifo_3_tready : std_logic;
    signal m_axis_fifo_4_tready : std_logic;
    signal m_axis_fifo_5_tready : std_logic;
    signal m_axis_fifo_6_tready : std_logic;
    signal m_axis_fifo_7_tready : std_logic;

    signal priority_fifo_almost_full : std_logic_vector(7 downto 0) := (others => '0');

    signal selected_fifo : integer := 0;

    signal current_input_metric_stream_index : integer := 0;
    signal current_input_metric_stream : metric_axi_stream_t;
    signal current_input_metric_stream_tready : std_logic;
    signal packet_available : std_logic := '0';

    signal current_output_metric_stream : metric_axi_stream_t;
    signal current_output_metric_stream_index : INTEGER := 0;
    signal current_output_metric_stream_tready : std_logic;

    signal metric_packet_priority_valid_array : std_logic_vector(7 downto 0);


    -- skid buffer registers

    signal reg_tdata   : std_logic_vector(7 downto 0);
    signal reg_tuser   : std_logic_vector(2 downto 0);
    signal reg_tvalid  : std_logic;
    signal reg_tlast   : std_logic;
    signal reg_tready  : std_logic;

begin

    process(clk, reset) 
    begin 
        if(rising_edge(clk)) then 
            if(reset = '1') then 
                current_input_arbiter_state <= ROUND_ROBIN;
            else 
                current_input_arbiter_state <= next_input_arbiter_state;
            end if;
        end if;
    end process;


    process (clk, reset) -- metric packet manager FSM (round robin and passthrough, also demux)
    begin 
        if(rising_edge(clk)) then 
            if(reset = '1') then
                current_input_metric_stream_index <= 0;
                next_input_arbiter_state <= ROUND_ROBIN;
                packet_available <= '0';
            else 
                case current_input_arbiter_state is
                    when ROUND_ROBIN => 
                        packet_available <= '0';
                        if current_input_metric_stream_index = metric_input_stream_amount-1 then --round robin through all streams
                            current_input_metric_stream_index <= 0;
                        else
                            current_input_metric_stream_index <= current_input_metric_stream_index + 1;
                        end if;

                        if s_axis(current_input_metric_stream_index).tvalid = '1' and current_input_metric_stream_tready = '1' then 
                            next_input_arbiter_state <= PASSTHROUGH;
                            packet_available <= '1';
                        end if;

                    when PASSTHROUGH =>
                        -- passthrough enabled
                        if((current_input_metric_stream.tlast = '1' and current_input_metric_stream.tvalid = '1') and current_input_metric_stream_tready = '1') then -- if last byte of the metric packet received, then go back to round robin
                            next_input_arbiter_state <= ROUND_ROBIN;
                            packet_available <= '0';
                        end if;
                end case;
            end if;
        end if;

    end process;

    s_axis_tready(current_input_metric_stream_index) <= current_input_metric_stream_tready;
    current_input_metric_stream <= s_axis(current_input_metric_stream_index);

    -- Combined register slice + latch process
    process(clk, reset)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                reg_tvalid <= '0';
                reg_tdata  <= (others => '0');
                reg_tuser  <= (others => '0');
                reg_tlast  <= '0';
                selected_fifo <= 0;
            else
                -- Default: keep reg_tvalid unless consumed or replaced below
                -- Case A: We currently hold a valid beat in register
                if reg_tvalid = '1' then
                    -- If downstream accepted this beat, clear reg_tvalid
                    if reg_tready = '1' then
                        reg_tvalid <= '0';
                        -- Optionally: if upstream also has a beat available in the
                        -- same cycle (and upstream tready was true), capture it
                        if (current_input_metric_stream.tvalid = '1' and
                            current_input_metric_stream_tready = '1') then
                            -- capture new beat immediately (pipeline)
                            reg_tdata  <= current_input_metric_stream.tdata;
                            reg_tuser  <= current_input_metric_stream.tuser;
                            reg_tlast  <= current_input_metric_stream.tlast;
                            reg_tvalid <= '1';
                            -- latch FIFO select for this new packet (start-of-packet)
                            -- We latch on acceptance (tvalid && tready) to be safe.
                            selected_fifo <= to_integer(unsigned(current_input_metric_stream.tuser));
                        end if;
                    end if;

                -- Case B: register empty, accept an upstream beat if it's available
                else  -- reg_tvalid = '0'
                    if (current_input_metric_stream.tvalid = '1' and
                        current_input_metric_stream_tready = '1') then
                        -- Accept the beat into the register
                        reg_tdata  <= current_input_metric_stream.tdata;
                        reg_tuser  <= current_input_metric_stream.tuser;
                        reg_tlast  <= current_input_metric_stream.tlast;
                        reg_tvalid <= '1';
                        -- Latch FIFO select at the moment we accepted the beat
                        selected_fifo <= to_integer(unsigned(current_input_metric_stream.tuser));
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- backpressure to upstream
    current_input_metric_stream_tready <= (not reg_tvalid) or reg_tready;

    ---------------------------------------------------------------------
    --  Demux (uses registered data + latched FIFO select)
    ---------------------------------------------------------------------
    process(clk, reset)
    begin
        if rising_edge(clk) then
            -- default assignments
            s_axis_fifo_0.tvalid <= '0';
            s_axis_fifo_1.tvalid <= '0';
            s_axis_fifo_2.tvalid <= '0';
            s_axis_fifo_3.tvalid <= '0';
            s_axis_fifo_4.tvalid <= '0';
            s_axis_fifo_5.tvalid <= '0';
            s_axis_fifo_6.tvalid <= '0';
            s_axis_fifo_7.tvalid <= '0';

            s_axis_fifo_0.tlast  <= '0';
            s_axis_fifo_1.tlast  <= '0';
            s_axis_fifo_2.tlast  <= '0';
            s_axis_fifo_3.tlast  <= '0';
            s_axis_fifo_4.tlast  <= '0';
            s_axis_fifo_5.tlast  <= '0';
            s_axis_fifo_6.tlast  <= '0';
            s_axis_fifo_7.tlast  <= '0';

            reg_tready <= '0';

            if reg_tvalid = '1' then
                case selected_fifo is
                    when 0 =>
                        s_axis_fifo_0.tdata  <= reg_tdata;
                        s_axis_fifo_0.tuser  <= reg_tuser;
                        s_axis_fifo_0.tvalid <= reg_tvalid and reg_tready;
                        s_axis_fifo_0.tlast  <= reg_tlast;
                        reg_tready           <= s_axis_fifo_0_tready;

                    when 1 =>
                        s_axis_fifo_1.tdata  <= reg_tdata;
                        s_axis_fifo_1.tuser  <= reg_tuser;
                        s_axis_fifo_1.tvalid <= reg_tvalid and reg_tready;
                        s_axis_fifo_1.tlast  <= reg_tlast;
                        reg_tready           <= s_axis_fifo_1_tready;

                    when 2 =>
                        s_axis_fifo_2.tdata  <= reg_tdata;
                        s_axis_fifo_2.tuser  <= reg_tuser;
                        s_axis_fifo_2.tvalid <= reg_tvalid and reg_tready;
                        s_axis_fifo_2.tlast  <= reg_tlast;
                        reg_tready           <= s_axis_fifo_2_tready;

                    when 3 =>
                        s_axis_fifo_3.tdata  <= reg_tdata;
                        s_axis_fifo_3.tuser  <= reg_tuser;
                        s_axis_fifo_3.tvalid <= reg_tvalid and reg_tready;
                        s_axis_fifo_3.tlast  <= reg_tlast;
                        reg_tready           <= s_axis_fifo_3_tready;

                    when 4 =>
                        s_axis_fifo_4.tdata  <= reg_tdata;
                        s_axis_fifo_4.tuser  <= reg_tuser;
                        s_axis_fifo_4.tvalid <= reg_tvalid and reg_tready;
                        s_axis_fifo_4.tlast  <= reg_tlast;
                        reg_tready           <= s_axis_fifo_4_tready;

                    when 5 =>
                        s_axis_fifo_5.tuser  <= reg_tuser;
                        s_axis_fifo_5.tdata  <= reg_tdata;
                        s_axis_fifo_5.tvalid <= reg_tvalid and reg_tready;
                        s_axis_fifo_5.tlast  <= reg_tlast;
                        reg_tready           <= s_axis_fifo_5_tready;

                    when 6 =>
                        s_axis_fifo_6.tdata  <= reg_tdata;
                        s_axis_fifo_6.tuser  <= reg_tuser;
                        s_axis_fifo_6.tvalid <= reg_tvalid and reg_tready;
                        s_axis_fifo_6.tlast  <= reg_tlast;
                        reg_tready           <= s_axis_fifo_6_tready;

                    when 7 =>
                        s_axis_fifo_7.tdata  <= reg_tdata;
                        s_axis_fifo_7.tuser  <= reg_tuser;
                        s_axis_fifo_7.tvalid <= reg_tvalid and reg_tready;
                        s_axis_fifo_7.tlast  <= reg_tlast;
                        reg_tready           <= s_axis_fifo_7_tready;

                    when others =>
                        reg_tready <= '0';
                end case;
            end if;
        end if;
    end process;
  
    -- async assignment of ready
    current_output_metric_stream_tready <= m_axis_tready;

    m_axis <= current_output_metric_stream; 


    -- priority arbiter

    metric_packet_priority_valid_array <= -- this helps the arbiter in the packet manager decide which packet to forward first
    m_axis_fifo_7.tvalid &
    m_axis_fifo_6.tvalid &
    m_axis_fifo_5.tvalid &
    m_axis_fifo_4.tvalid &
    m_axis_fifo_3.tvalid &
    m_axis_fifo_2.tvalid &
    m_axis_fifo_1.tvalid &
    m_axis_fifo_0.tvalid;

    process (clk, reset, current_output_arbiter_state, current_output_metric_stream_index, current_output_metric_stream_tready) 
    begin 
        m_axis_fifo_0_tready <= '0';
        m_axis_fifo_1_tready <= '0';
        m_axis_fifo_2_tready <= '0';
        m_axis_fifo_3_tready <= '0';
        m_axis_fifo_4_tready <= '0';
        m_axis_fifo_5_tready <= '0';
        m_axis_fifo_6_tready <= '0';
        m_axis_fifo_7_tready <= '0';

        if(current_output_arbiter_state = PASSTHROUGH_TO_OUTPUT) then 
            case current_output_metric_stream_index is  
                when 0 => m_axis_fifo_0_tready <= current_output_metric_stream_tready;
                when 1 => m_axis_fifo_1_tready <= current_output_metric_stream_tready;
                when 2 => m_axis_fifo_2_tready <= current_output_metric_stream_tready;
                when 3 => m_axis_fifo_3_tready <= current_output_metric_stream_tready;
                when 4 => m_axis_fifo_4_tready <= current_output_metric_stream_tready;
                when 5 => m_axis_fifo_5_tready <= current_output_metric_stream_tready;
                when 6 => m_axis_fifo_6_tready <= current_output_metric_stream_tready;
                when 7 => m_axis_fifo_7_tready <= current_output_metric_stream_tready;
                when others => m_axis_fifo_0_tready <= current_output_metric_stream_tready;
            end case;
        else 
            m_axis_fifo_0_tready <= '0';
            m_axis_fifo_1_tready <= '0';
            m_axis_fifo_2_tready <= '0';
            m_axis_fifo_3_tready <= '0';
            m_axis_fifo_4_tready <= '0';
            m_axis_fifo_5_tready <= '0';
            m_axis_fifo_6_tready <= '0';
            m_axis_fifo_7_tready <= '0';
        end if;
    end process;

    process (clk, reset) 
    begin 
        -- initial default values
        if rising_edge(clk) then
            if(reset = '1') then 
                current_output_metric_stream_index <= 0;
                current_output_arbiter_state <= CHECK_AVAILABLE_FIFO_DATA;
            else 
                case current_output_arbiter_state is  
                
                when CHECK_AVAILABLE_FIFO_DATA =>
                    
                    -- highest priority first
                    for i in 0 to 7 loop 
                        if(metric_packet_priority_valid_array(i) = '1') then 
                            current_output_arbiter_state <= PASSTHROUGH_TO_OUTPUT;
                            current_output_metric_stream_index <= i;
                            exit;  -- First-match priority
                        end if;
                    end loop;

                when PASSTHROUGH_TO_OUTPUT => 
                        
                    if(current_output_metric_stream.tlast = '1' and current_output_metric_stream.tvalid = '1' and current_output_metric_stream_tready = '1') then 
                        current_output_arbiter_state <= CHECK_AVAILABLE_FIFO_DATA;
                    end if;

                end case;
            end if;
        end if;
    end process;

        -- COMBINATIONAL mux for forward path
    process (current_output_arbiter_state, current_output_metric_stream_index,
            m_axis_fifo_0, m_axis_fifo_1, m_axis_fifo_2, m_axis_fifo_3,
            m_axis_fifo_4, m_axis_fifo_5, m_axis_fifo_6, m_axis_fifo_7)
    begin
        if current_output_arbiter_state = PASSTHROUGH_TO_OUTPUT then
            
            case current_output_metric_stream_index is  
                when 0 => current_output_metric_stream <= m_axis_fifo_0;
                when 1 => current_output_metric_stream <= m_axis_fifo_1;
                when 2 => current_output_metric_stream <= m_axis_fifo_2;
                when 3 => current_output_metric_stream <= m_axis_fifo_3;
                when 4 => current_output_metric_stream <= m_axis_fifo_4;
                when 5 => current_output_metric_stream <= m_axis_fifo_5;
                when 6 => current_output_metric_stream <= m_axis_fifo_6;
                when 7 => current_output_metric_stream <= m_axis_fifo_7;
                when others => current_output_metric_stream <= m_axis_fifo_0;
            end case;
            
        else
            current_output_metric_stream.tvalid <= '0';
            current_output_metric_stream.tdata <= (others => '0');
            current_output_metric_stream.tlast <= '0';
            current_output_metric_stream.tuser <= (others => '0');
        end if;
    end process;
    
    priority_fifo_0 : priority_axis_data_fifo
     generic map(
        g_WIDTH => 10,
        g_DEPTH => 2047
    )
     port map(
        i_clk => clk,
        i_rst_sync => reset,
        s_axis_tvalid => s_axis_fifo_0.tvalid,
        s_axis_tdata => s_axis_fifo_0.tdata,
        s_axis_tlast => s_axis_fifo_0.tlast,
        s_axis_tready => s_axis_fifo_0_tready,
        m_axis_tvalid => m_axis_fifo_0.tvalid,
        m_axis_tdata => m_axis_fifo_0.tdata,
        m_axis_tlast => m_axis_fifo_0.tlast,
        m_axis_tready => m_axis_fifo_0_tready,
        almost_full => priority_fifo_almost_full(0)
    );

    priority_fifo_1 : priority_axis_data_fifo
     generic map(
        g_WIDTH => 10,
        g_DEPTH => 2047
    )
     port map(
        i_clk => clk,
        i_rst_sync => reset,
        s_axis_tvalid => s_axis_fifo_1.tvalid,
        s_axis_tdata => s_axis_fifo_1.tdata,
        s_axis_tlast => s_axis_fifo_1.tlast,
        s_axis_tready => s_axis_fifo_1_tready,
        m_axis_tvalid => m_axis_fifo_1.tvalid,
        m_axis_tdata => m_axis_fifo_1.tdata,
        m_axis_tlast => m_axis_fifo_1.tlast,
        m_axis_tready => m_axis_fifo_1_tready,
        almost_full => priority_fifo_almost_full(1)
    );

    priority_fifo_2 : priority_axis_data_fifo
     generic map(
        g_WIDTH => 10,
        g_DEPTH => 2047
    )
     port map(
        i_clk => clk,
        i_rst_sync => reset,
        s_axis_tvalid => s_axis_fifo_2.tvalid,
        s_axis_tdata => s_axis_fifo_2.tdata,
        s_axis_tlast => s_axis_fifo_2.tlast,
        s_axis_tready => s_axis_fifo_2_tready,
        m_axis_tvalid => m_axis_fifo_2.tvalid,
        m_axis_tdata => m_axis_fifo_2.tdata,
        m_axis_tlast => m_axis_fifo_2.tlast,
        m_axis_tready => m_axis_fifo_2_tready,
        almost_full => priority_fifo_almost_full(2)
    );

    priority_fifo_3 : priority_axis_data_fifo
     generic map(
        g_WIDTH => 10,
        g_DEPTH => 2047
    )
     port map(
        i_clk => clk,
        i_rst_sync => reset,
        s_axis_tvalid => s_axis_fifo_3.tvalid,
        s_axis_tdata => s_axis_fifo_3.tdata,
        s_axis_tlast => s_axis_fifo_3.tlast,
        s_axis_tready => s_axis_fifo_3_tready,
        m_axis_tvalid => m_axis_fifo_3.tvalid,
        m_axis_tdata => m_axis_fifo_3.tdata,
        m_axis_tlast => m_axis_fifo_3.tlast,
        m_axis_tready => m_axis_fifo_3_tready,
        almost_full => priority_fifo_almost_full(3)
    );

    priority_fifo_4 : priority_axis_data_fifo
     generic map(
        g_WIDTH => 10,
        g_DEPTH => 2047
    )
     port map(
        i_clk => clk,
        i_rst_sync => reset,
        s_axis_tvalid => s_axis_fifo_4.tvalid,
        s_axis_tdata => s_axis_fifo_4.tdata,
        s_axis_tlast => s_axis_fifo_4.tlast,
        s_axis_tready => s_axis_fifo_4_tready,
        m_axis_tvalid => m_axis_fifo_4.tvalid,
        m_axis_tdata => m_axis_fifo_4.tdata,
        m_axis_tlast => m_axis_fifo_4.tlast,
        m_axis_tready => m_axis_fifo_4_tready,
        almost_full => priority_fifo_almost_full(4)
    );

    priority_fifo_5 : priority_axis_data_fifo
     generic map(
        g_WIDTH => 10,
        g_DEPTH => 2047
    )
     port map(
        i_clk => clk,
        i_rst_sync => reset,
        s_axis_tvalid => s_axis_fifo_5.tvalid,
        s_axis_tdata => s_axis_fifo_5.tdata,
        s_axis_tlast => s_axis_fifo_5.tlast,
        s_axis_tready => s_axis_fifo_5_tready,
        m_axis_tvalid => m_axis_fifo_5.tvalid,
        m_axis_tdata => m_axis_fifo_5.tdata,
        m_axis_tlast => m_axis_fifo_5.tlast,
        m_axis_tready => m_axis_fifo_5_tready,
        almost_full => priority_fifo_almost_full(5)
    );

    priority_fifo_6 : priority_axis_data_fifo
     generic map(
        g_WIDTH => 10,
        g_DEPTH => 2047
    )
     port map(
        i_clk => clk,
        i_rst_sync => reset,
        s_axis_tvalid => s_axis_fifo_6.tvalid,
        s_axis_tdata => s_axis_fifo_6.tdata,
        s_axis_tlast => s_axis_fifo_6.tlast,
        s_axis_tready => s_axis_fifo_6_tready,
        m_axis_tvalid => m_axis_fifo_6.tvalid,
        m_axis_tdata => m_axis_fifo_6.tdata,
        m_axis_tlast => m_axis_fifo_6.tlast,
        m_axis_tready => m_axis_fifo_6_tready,
        almost_full => priority_fifo_almost_full(6)
    );

    priority_fifo_7 : priority_axis_data_fifo
     generic map(
        g_WIDTH => 10,
        g_DEPTH => 2047
    )
     port map(
        i_clk => clk,
        i_rst_sync => reset,
        s_axis_tvalid => s_axis_fifo_7.tvalid,
        s_axis_tdata => s_axis_fifo_7.tdata,
        s_axis_tlast => s_axis_fifo_7.tlast,
        s_axis_tready => s_axis_fifo_7_tready,
        m_axis_tvalid => m_axis_fifo_7.tvalid,
        m_axis_tdata => m_axis_fifo_7.tdata,
        m_axis_tlast => m_axis_fifo_7.tlast,
        m_axis_tready => m_axis_fifo_7_tready,
        almost_full => priority_fifo_almost_full(7)
    );
    
        -- this looks dumb but works great as user field is known from priority fifo index
        m_axis_fifo_0.tuser <= "000";
        m_axis_fifo_1.tuser <= "001";
        m_axis_fifo_2.tuser <= "010";
        m_axis_fifo_3.tuser <= "011";
        m_axis_fifo_4.tuser <= "100";
        m_axis_fifo_5.tuser <= "101";
        m_axis_fifo_6.tuser <= "110";
        m_axis_fifo_7.tuser <= "111";

        almost_full_vector <= priority_fifo_almost_full;

end Behavioral;