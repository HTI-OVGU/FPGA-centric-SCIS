library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.metric_axi_stream_pkg.all;

entity data_concentrator_tb is
end data_concentrator_tb;

architecture Behavioral of data_concentrator_tb is

    -- Component declaration
    component data_concentrator is
        generic (
            input_channel_amount : natural := 1
        );
        port (
            clk         : in  STD_LOGIC;
            reset       : in  STD_LOGIC;
            tdata       : out STD_LOGIC_VECTOR(7 downto 0);
            tvalid      : out STD_LOGIC;
            tlast       : out STD_LOGIC;
            tready      : in  STD_LOGIC;
            tuser       : out STD_LOGIC_VECTOR(2 downto 0);
            s_axis: in metric_axi_stream_array_t(input_channel_amount-1 to 0);
            s_axis_ready : out std_logic_vector(input_channel_amount-1 downto 0);
            interlock  : out STD_LOGIC;
            deassert_interlock : in STD_LOGIC;
            ext_interlock_source : in STD_LOGIC
        );
    end component;

    -- Clock period definition
    constant CLK_PERIOD : time := 10 ns; -- 100 MHz clock

    -- Test data sequence:
    type metric_byte_array is array (0 to 8) of STD_LOGIC_VECTOR(7 downto 0);

    constant METRIC_PACKET_TEST_0 : metric_byte_array := (
        x"56", x"30", x"31", x"50", x"31",  --V01P1
        x"FF", x"00", x"00", x"12" -- 32 bit QM.N value  
        );

    type byte_array is array (0 to 16) of STD_LOGIC_VECTOR(7 downto 0);
    constant TEST_DATA_0 : byte_array := (
        x"C0", x"A8", x"02", x"6A",-- 192.168.2.100
        x"00", x"D9", x"00", x"09", -- 00D9 (Port)  000B (packet Length 11) 
        x"56", x"30", x"31", x"50", x"31",  --V01P1
        x"FF", x"00", x"00", x"12" -- 32 bit QM.N value  
        );

    constant TEST_DATA_1 : byte_array := (
        x"C0", x"A8", x"02", x"6A",-- 192.168.2.100
        x"00", x"D9", x"00", x"09", -- 00D9 (Port)  0009 (packet Length 11) 
        x"56", x"30", x"31", x"00", x"01",  --V0101
        x"34", x"35", x"39", x"2e" -- 32 bit QM.N value  
        );

    -- Testbench signals
    signal clk         : STD_LOGIC := '0';
    signal reset       : STD_LOGIC := '1';
    signal tdata       : STD_LOGIC_VECTOR(7 downto 0);
    signal tvalid      : STD_LOGIC;
    signal tlast       : STD_LOGIC;
    signal tready      : STD_LOGIC := '1';
    signal tuser       : STD_LOGIC_VECTOR(2 downto 0);
    signal rdata       : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal rlast       : STD_LOGIC := '0';
    signal rvalid      : STD_LOGIC := '0';
    signal rready      : STD_LOGIC;
    signal ruser       : STD_LOGIC_VECTOR(2 downto 0) := (others => '0');
    signal interlock : STD_LOGIC := '0';
    signal deassert_interlock : STD_LOGIC := '0';
    signal ext_interlock_source : std_logic := '0';


    -- Control signals
    signal sim_end     : boolean := false;

    -- signals after adapter:

	signal data_concentrator_input_vector : metric_axi_stream_array_t(0 downto 0);
	signal data_concentrator_ready_input_vector : std_logic_vector(0 downto 0);

begin
    -- Instantiate the Device Under Test (DUT)

    data_concentrator_input_vector(0).tvalid <= rvalid;
    data_concentrator_input_vector(0).tlast <= rlast;
    data_concentrator_input_vector(0).tdata <= rdata;
    data_concentrator_input_vector(0).tuser <= ruser;
	rready <= data_concentrator_ready_input_vector(0);
    
    data_concentrator_unit: data_concentrator
        port map (
            clk    => clk,
            reset  => reset,
            tdata  => tdata,
            tvalid => tvalid,
            tlast  => tlast,
            tready => tready,
            tuser  => tuser,
            s_axis => data_concentrator_input_vector,            
            s_axis_ready => data_concentrator_ready_input_vector,
            interlock => interlock,
            deassert_interlock => deassert_interlock,
            ext_interlock_source => ext_interlock_source
            );

    -- Clock generation process
    clk_process: process
    begin
        while not sim_end loop
            clk <= '0';
            wait for CLK_PERIOD/2;
            clk <= '1';
            wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    -- Stimulus process
    stim_proc: process
    begin
        -- Initialize
        reset <= '1';
        rvalid <= '0';
        rlast <= '0';
        rdata <= (others => '0');
        ruser <= (others => '0');
        tready <= '0';
        deassert_interlock <= '0';

        -- Wait for a few clock cycles
        wait for CLK_PERIOD * 5;
        
        -- Release reset
        reset <= '0';
        wait for CLK_PERIOD * 2;

        -- Wait a short amount of time before asserting rvalid
        wait for CLK_PERIOD * 3;

        report "Starting data transmission...";

        -- Send FIRST test data sequence
        for i in 0 to 8 loop  
            -- Set up data
            wait until falling_edge(clk);

            rdata <= METRIC_PACKET_TEST_0(i);
            ruser <= "010"; -- Example user signal, priority 2
            rvalid <= '1';
    
            -- Assert rlast for the last byte
            if i = 8 then
                rlast <= '1';
            else
                rlast <= '0';
            end if;

            -- Wait for rready to be asserted by DUT
            wait until rising_edge(clk);

            if rready = '0' then
                -- Wait for rready to go high
                while rready = '0' loop
                    wait until rising_edge(clk);
                end loop;
            end if;
            
            -- Deassert rvalid on falling edge (simulate slow source)
            --wait until rising_edge(clk);
            -- rvalid <= '0';
            -- rlast <= '0';
            
            -- Keep invalid for 7 clock cycles
            -- wait for CLK_PERIOD * 7;
            
        end loop;

        rvalid <= '0';
        -- Wait a short amount of time before asserting rvalid
        wait for CLK_PERIOD * 4;
        
        report "complete, waiting until tvalid = '1'";


        if tvalid = '1' then 
            tready <= '1';
        else 
            tready <= '0';
        end if;
        
        wait until tlast = '1';
        wait for CLK_PERIOD * 2;
        tready <= '0';

        -- Send SECOND (long) test data sequence PART 1
        for i in 0 to 16 loop  
            -- Set up data
            wait until falling_edge(clk);

            rdata <= TEST_DATA_0(i);
            ruser <= "010"; -- Example user signal, priority 2
            rvalid <= '1';
    
            -- Assert rlast for the last byte
            if i = 16 then
                rlast <= '1';
            else
                rlast <= '0';
            end if;

            -- Wait for rready to be asserted by DUT
            wait until rising_edge(clk);

            if rready = '0' then
                -- Wait for rready to go high
                while rready = '0' loop
                    wait until rising_edge(clk);
                end loop;
            end if;
            
            -- Deassert rvalid on falling edge (simulate slow source)
            wait until falling_edge(clk);
            rvalid <= '0';
            rlast <= '0';
            
            -- Keep invalid for 7 clock cycles
            wait for CLK_PERIOD * 7;
            
        end loop;
        
        -- Send SECOND (long) test data sequence PART 2
        for i in 0 to 16 loop  
            -- Set up data
            wait until falling_edge(clk);

            rdata <= TEST_DATA_1(i);
            ruser <= "010"; -- Example user signal, priority 2
            rvalid <= '1';
    
            -- Assert rlast for the last byte
            if i = 16 then
                rlast <= '1';
            else
                rlast <= '0';
            end if;

            -- Wait for rready to be asserted by DUT
            wait until rising_edge(clk);

            if rready = '0' then
                -- Wait for rready to go high
                while rready = '0' loop
                    wait until rising_edge(clk);
                end loop;
            end if;
            
            -- Deassert rvalid on falling edge (simulate slow source)
            wait until falling_edge(clk);
            rvalid <= '0';
            rlast <= '0';
            
            -- Keep invalid for 7 clock cycles
            wait for CLK_PERIOD * 7;
            
        end loop;


        report "Data transmission completed";
        
        -- HERE interlock SHOULD BE ASSERTED;

        wait until interlock = '1';

        wait for CLK_PERIOD * 30;

        -- Send THRIDT test data sequence ( while interlock is asserted high)
        for i in 0 to 16 loop  
            -- Set up data
            rdata <= TEST_DATA_0(i);
            ruser <= "010"; -- Example user signal, priority 2
            rvalid <= '1';

            -- Assert rlast for the last byte
            if i = 16 then
                rlast <= '1';
            else
                rlast <= '0';
            end if;

            -- Wait for rready to be asserted by DUT
            wait until rising_edge(clk);
            while rready = '0' loop
                wait until rising_edge(clk);
            end loop;

            report "DUT asserted rready for byte " & integer'image(i) & " at time " & time'image(now);

            -- Hold for one clock cycle to complete the handshake
            
        end loop;

        rvalid <= '0';
        
        wait for CLK_PERIOD * 40;
        
        deassert_interlock <= '1';

        -- Send FOURTH test data sequence (after deassertion of interlock, regular usage)
        for i in 0 to 16 loop  
            -- Set up data
            rdata <= TEST_DATA_0(i);
            ruser <= "010"; -- Example user signal, priority 2
            rvalid <= '1';

            -- Assert rlast for the last byte
            if i = 16 then
                rlast <= '1';
            else
                rlast <= '0';
            end if;

            -- Wait for rready to be asserted by DUT
            wait until rising_edge(clk);
            while rready = '0' loop
                wait until rising_edge(clk);
            end loop;

            report "DUT asserted rready for byte " & integer'image(i) & " at time " & time'image(now);

            -- Hold for one clock cycle to complete the handshake
            
        end loop;

        rvalid <= '0';

        wait for CLK_PERIOD * 20;
        
        deassert_interlock <= '0';

        -- Wait some more time to observe output
        wait for CLK_PERIOD * 100;

        -- End simulation
        report "Testbench completed successfully";
        sim_end <= true;
        wait;
    end process;

    -- Optional: Monitor process to display output data
    monitor_proc: process
    begin
        wait until reset = '0';
        
        while not sim_end loop
            wait until rising_edge(clk);
            if tvalid = '1' and tready = '1' then
                report "Output data: 0x" & 
                       ", tlast=" & std_logic'image(tlast) & 
                       ", tuser=" &
                       " at time " & time'image(now);
            end if;
        end loop;
        wait;
    end process;

end Behavioral;