library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.metric_axi_stream_pkg.all;
use work.threshold_tables_pkg.all;

entity data_concentrator is
    generic (
        input_channel_amount : natural := 1
    );
    port (
        clk         : in  STD_LOGIC;
        reset       : in  STD_LOGIC;
        -- t side goes towards w5500 dedicated for sending
        tdata       : out STD_LOGIC_VECTOR(7 downto 0);
        tvalid      : out STD_LOGIC;
        tlast       : out STD_LOGIC;
        tready      : in  STD_LOGIC;
        tuser       : out STD_LOGIC_VECTOR(2 downto 0);
        -- r side are input channels for metric packets
        s_axis: in metric_axi_stream_array_t(input_channel_amount-1 downto 0);
        s_axis_ready : out std_logic_vector(input_channel_amount-1 downto 0);
        interlock  : out STD_LOGIC;
        deassert_interlock : in STD_LOGIC;
        ext_interlock_source : in STD_LOGIC
    );
end data_concentrator;

architecture Behavioral of data_concentrator is

    -- towards the thresholding logic
    signal s_metric_axis_0 : metric_axi_stream_t;
    signal s_metric_axis_0_tready : std_logic;
    -- after thresholding_logic;
    signal m_metric_axis_0 : metric_axi_stream_t;
    signal m_metric_axis_0_tready : std_logic;

    signal int_rdata_from_w5500_controller : std_logic_vector(7 downto 0);
    signal int_debug_output_signals : std_logic_vector(7 downto 0);

    signal metric_packet_s_axis_array : metric_axi_stream_array_t(0 to input_channel_amount-1);
    signal metric_packet_s_axis_tready_array : std_logic_vector(input_channel_amount-1 downto 0);
    signal metric_packet_m_axis : metric_axi_stream_t;

    -- per-channel threshold_logic outputs + interlocks (one threshold_logic per input channel)
    signal post_threshold_axis        : metric_axi_stream_array_t(0 to input_channel_amount-1);
    signal post_threshold_axis_tready : std_logic_vector(input_channel_amount-1 downto 0);
    signal interlock_vec              : std_logic_vector(input_channel_amount-1 downto 0);

    signal interlock_metric_packet_s_axis : metric_axi_stream_t;
    signal interlock_metric_packet_s_axis_tready : std_logic;

    signal interlock_metric_packet_m_axis : metric_axi_stream_t;
    signal int_almost_full_vector : std_logic_vector(7 downto 0);

    signal int_global_interlock : std_logic := '0';

    signal interlock_0 : std_logic := '0';
    signal filtered_ext_interlock : std_logic := '0';

    component interlock_glitch_filter is 
        port (
            clk         : in  STD_LOGIC;
            reset       : in  STD_LOGIC;
            interlock_in : in STD_LOGIC;
            interlock_out  : out STD_LOGIC
        );
    end component;


    component threshold_logic is
        generic (
            INIT_TABLE : threshold_table_t := ZERO_THRESHOLD_TABLE
        );
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
            deassert_interlock : in std_logic
        );
    end component;

    component metric_packet_manager is 
        generic (
            metric_input_stream_amount : INTEGER := 1
        );
        port (
            clk   : in std_logic;
            reset : in std_logic;
            s_axis: in metric_axi_stream_array_t(0 to metric_input_stream_amount-1); -- these are the metric packet streams coming in
            s_axis_tready : out std_logic_vector(metric_input_stream_amount-1 downto 0);
            m_axis : out metric_axi_stream_t; -- towards the threshold logic
            m_axis_tready : in std_logic;
            almost_full_vector : out std_logic_vector(7 downto 0)
        );
    end component;

    component telemetry_sender is
    port (
        clk         : in  STD_LOGIC;
        reset       : in  STD_LOGIC;
        m_axis_data       : out STD_LOGIC_VECTOR(7 downto 0);
        m_axis_valid      : out STD_LOGIC;
        m_axis_last       : out STD_LOGIC;
        m_axis_ready      : in  STD_LOGIC;
        m_axis_user       : out STD_LOGIC_VECTOR(2 downto 0);
        s_axis_data       : in  STD_LOGIC_VECTOR(7 downto 0);
        s_axis_last       : in  STD_LOGIC;
        s_axis_valid      : in  STD_LOGIC;
        s_axis_ready      : out STD_LOGIC;
        s_axis_user       : in  STD_LOGIC_VECTOR(2 downto 0);
        interlock  : in STD_LOGIC;
        almost_full_vector : in STD_LOGIC_VECTOR(7 downto 0)
    );
    end component;


begin

    -- One threshold_logic per input channel. Each parses its own metric stream,
    -- raises its own interlock, and feeds one input of the metric_packet_manager.
    gen_threshold_per_channel : for ch in 0 to input_channel_amount-1 generate
        unit_threshold_logic : threshold_logic
         generic map(
            -- each channel gets its own compile-time table (thesis 5.3: 1024
            -- threshold pairs per input channel); channels beyond the tables
            -- defined in threshold_tables_pkg fall back to the zero table
            INIT_TABLE => CHANNEL_THRESHOLD_TABLES(ch)
        )
         port map(
            clk => clk,
            reset => reset,
            tdata => post_threshold_axis(ch).tdata,
            tvalid => post_threshold_axis(ch).tvalid,
            tlast => post_threshold_axis(ch).tlast,
            tready => post_threshold_axis_tready(ch),
            tuser => post_threshold_axis(ch).tuser,
            rdata => s_axis(ch).tdata,
            rlast => s_axis(ch).tlast,
            rvalid => s_axis(ch).tvalid,
            rready => s_axis_ready(ch),
            ruser => s_axis(ch).tuser,
            interlock => interlock_vec(ch),
            deassert_interlock => deassert_interlock
        );

        metric_packet_s_axis_array(ch)        <= post_threshold_axis(ch);
        post_threshold_axis_tready(ch)        <= metric_packet_s_axis_tready_array(ch);
    end generate gen_threshold_per_channel;

    -- global interlock = OR of every channel's interlock, plus the filtered external
    -- source. Explicit loop (not the VHDL-2008 "or" reduction) so this file still
    -- compiles under plain VHDL-93 (e.g. the sim_all Makefile target).
    interlock_reduce : process(interlock_vec, filtered_ext_interlock)
        variable v : std_logic;
    begin
        v := '0';
        for i in interlock_vec'range loop
            v := v or interlock_vec(i);
        end loop;
        int_global_interlock <= v or filtered_ext_interlock;
    end process;

    interlock <= int_global_interlock;

    unit_interlock_glitch_filter : interlock_glitch_filter
     port map(
        clk => clk,
        reset => reset,
        interlock_in => ext_interlock_source,
        interlock_out => filtered_ext_interlock
    );

    unit_telemetry_sender : telemetry_sender 
    port map(
        clk => clk,
        reset => reset,
        s_axis_data => interlock_metric_packet_s_axis.tdata,
        s_axis_user => interlock_metric_packet_s_axis.tuser,
        s_axis_valid => interlock_metric_packet_s_axis.tvalid,
        s_axis_last => interlock_metric_packet_s_axis.tlast,
        s_axis_ready => interlock_metric_packet_s_axis_tready,
        m_axis_data => metric_packet_m_axis.tdata,
        m_axis_valid => metric_packet_m_axis.tvalid,
        m_axis_user => metric_packet_m_axis.tuser,
        m_axis_last => metric_packet_m_axis.tlast,
        m_axis_ready => tready,
        interlock => int_global_interlock,
        almost_full_vector => int_almost_full_vector
    );


    -- (per-channel stream <-> manager wiring is done in gen_threshold_per_channel above)

    unit_metric_packet_manager : metric_packet_manager
     generic map(
        metric_input_stream_amount => input_channel_amount
    )
     port map(
        clk => clk,
        reset => reset,
        s_axis => metric_packet_s_axis_array,
        s_axis_tready => metric_packet_s_axis_tready_array,
        m_axis => interlock_metric_packet_s_axis,
        m_axis_tready => interlock_metric_packet_s_axis_tready,
        almost_full_vector => int_almost_full_vector
    );

    tdata <= metric_packet_m_axis.tdata;
    tuser <= metric_packet_m_axis.tuser;
    tvalid <= metric_packet_m_axis.tvalid;
    tlast <= metric_packet_m_axis.tlast;

end Behavioral;