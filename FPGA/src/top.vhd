----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 06.09.2024 10:31:17
-- Design Name: 
-- Module Name: top - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: This version runs directly from the board's main clock input.
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Revision 0.02 - Removed clock wizard to use direct board clock.
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.metric_axi_stream_pkg.all;

entity top is
    	port (
		-- This is the main clock from the board's oscillator (e.g., 10 MHz)
		clk:  in  std_logic;
		button: in  std_logic := '0';
		-- ext_interlock_source : in std_logic := '0';
		
		-- SPI Interface TX W5500
		mosi_0: out std_logic;
		miso_0: in  std_logic := '0';
		sclk_0: out std_logic;
		cs_0:   out std_logic;

		-- SPI Interface RX W5500
		mosi_1: out std_logic;
		miso_1: in  std_logic := '0';
		sclk_1: out std_logic;
		cs_1:   out std_logic;
		onboard_leds : out std_logic_vector(7 downto 0)
	);
end top;

architecture Behavioral of top is

    component CC_PLL is
	generic (
		REF_CLK         : string;  -- reference input in MHz
		OUT_CLK         : string;  -- pll output frequency in MHz
		PERF_MD         : string;  -- LOWPOWER, ECONOMY, SPEED
		LOW_JITTER      : integer; -- 0: disable, 1: enable low jitter mode
		CI_FILTER_CONST : integer; -- optional CI filter constant
		CP_FILTER_CONST : integer  -- optional CP filter constant
	);
	port (
		CLK_REF             : in  std_logic;
		USR_CLK_REF         : in  std_logic;
		CLK_FEEDBACK        : in  std_logic;
		USR_LOCKED_STDY_RST : in  std_logic;
		USR_PLL_LOCKED_STDY : out std_logic;
		USR_PLL_LOCKED      : out std_logic;
		CLK0                : out std_logic;
		CLK90               : out std_logic;
		CLK180              : out std_logic;
		CLK270              : out std_logic;
		CLK_REF_OUT         : out std_logic
	);
	end component;

	signal clk0    : std_logic;
	signal w5500_controller_debug_signal : STD_LOGIC_VECTOR(7 downto 0);

    component spi_master

        port (
			clk:    in std_logic;
			reset:  in std_logic;
			mosi:  out std_logic;
			miso:   in std_logic;
			sclk:  out std_logic;
			cs:    out std_logic;
            tdata:   in std_logic_vector (7 downto 0); -- data to send
            tvalid:    in std_logic;
		    tready :   out std_logic;
		    tlast : in std_logic;
		    rdata:  out std_logic_vector (7 downto 0); -- data received
		    rvalid :   out std_logic;
		    rready :   in std_logic;
		    rlast : out std_logic;
		    spi_busy: out std_logic
		);
	end component;
	
	component w5500_state_machine
	generic (
    	socket_amount : integer; -- all 8 sockets to be opened
		DEFAULT_ROUTINE : string;
		mac_address : std_logic_vector(47 downto 0) := x"D47F39AE92B1";
		source_ip_address : std_logic_vector(31 downto 0) := x"C0A80264"; --local ip address   192 168 2 100
    	dest_ip_address   : std_logic_vector(31 downto 0) := x"C0A8026A"; --destination ip address  192 168 2 106
    	source_udp_port   : std_logic_vector(15 downto 0) := x"2401"; -- local udp port   217
    	dest_udp_port     : std_logic_vector(15 downto 0) := x"2401" --destination udp port   217
  		);
	port(
        clk:    in std_logic;
		reset:  in std_logic;
        spi_busy: in std_logic := '0';
        tdata:   out std_logic_vector (7 downto 0); -- data to send
		tvalid:    out std_logic; -- axi stream from statemachine to spi master
		tready :   in std_logic; 
		tlast :    out std_logic;
		rdata:     in std_logic_vector (7 downto 0); -- data received
		rvalid :   in std_logic; -- axi stream from spi master to state machine
		rready :   out std_logic;
		rlast :    in std_logic;
		ext_pl_tdata:   in std_logic_vector (7 downto 0); -- payload data to send from external source
		ext_pl_tready : out std_logic;
		ext_pl_tvalid : in std_logic;
		ext_pl_tlast : in std_logic;
		ext_pl_tuser  : in std_logic_vector (2 downto 0); -- requests socket number (0-7)
		ext_pl_rdata:  out std_logic_vector (7 downto 0); -- payload data that has been received from the w5500 provided for external source
        ext_pl_rready : in std_logic := '1';
		ext_pl_rvalid : out std_logic;
		ext_pl_rlast : out std_logic;
		ext_pl_ruser  : out std_logic_vector (2 downto 0) -- received from socket number (0-7)
        );                       
    end component;
    
	component udp_packet_adapter is 
        port(
            clk         : in  STD_LOGIC;
            reset       : in  STD_LOGIC;
            rdata       : in  STD_LOGIC_VECTOR(7 downto 0);
            rlast       : in  STD_LOGIC;
            rvalid      : in  STD_LOGIC;
            rready      : out STD_LOGIC;
            ruser       : in  STD_LOGIC_VECTOR(2 downto 0);
            tready      : in  STD_LOGIC;
            tvalid      : out STD_LOGIC;
            tuser       : out STD_LOGIC_VECTOR(2 downto 0);
            tlast       : out STD_LOGIC;
            tdata       : out STD_LOGIC_VECTOR(7 downto 0)
        );
    end component;

    component data_concentrator
		generic (
        	input_channel_amount : natural := 1
    	);
        port(
            clk         : in  STD_LOGIC;
            reset         : in  STD_LOGIC;
            tdata       : out STD_LOGIC_VECTOR(7 downto 0);
            tvalid      : out STD_LOGIC;
            tlast       : out STD_LOGIC;
            tready      : in  STD_LOGIC;
			tuser 		: out STD_LOGIC_VECTOR(2 downto 0);
			s_axis		: in metric_axi_stream_array_t(input_channel_amount-1 to 0);
            s_axis_ready: out std_logic_vector(input_channel_amount-1 downto 0);
            interlock  : out STD_LOGIC;
            deassert_interlock : in std_logic;
			ext_interlock_source : in std_logic
			);
    end component;

--Outputs
    signal spi_busy_0: std_logic;
	signal spi_busy_1: std_logic;
    	
-- w5500 data signals
    signal tdata_0 : std_logic_vector(7 downto 0) := (others => '0');
    signal rdata_0 : std_logic_vector(7 downto 0) := (others => '0');
    signal tvalid_0, rvalid_0, tready_0, rready_0, rlast_0, tlast_0 : std_logic;


	signal tdata_1 : std_logic_vector(7 downto 0) := (others => '0');
    signal rdata_1 : std_logic_vector(7 downto 0) := (others => '0');
	signal tvalid_1, rvalid_1, tready_1, rready_1, rlast_1, tlast_1 : std_logic;

	signal packet_received_0, packet_received_1 : std_logic;	
    
    -- Hardware IO simulation signals
    signal ext_pl_tdata_0 : std_logic_vector(7 downto 0);
	signal ext_pl_tvalid_0 : std_logic := '1';
	signal ext_pl_tready_0 : std_logic;
	signal ext_pl_tlast_0 : std_logic:='0';
    signal ext_pl_rdata_0 : std_logic_vector(7 downto 0);
	signal ext_pl_rvalid_0 : std_logic;
	signal ext_pl_rready_0 : std_logic := '1';
	signal ext_pl_rlast_0 : std_logic;
	signal ext_pl_tuser_0 : std_logic_vector(2 downto 0) := (others => '0');
	signal ext_pl_ruser_0 : std_logic_vector(2 downto 0) := (others => '0');

	signal ext_pl_tdata_1 : std_logic_vector(7 downto 0);
	signal ext_pl_tvalid_1 : std_logic := '1';
	signal ext_pl_tready_1 : std_logic;
	signal ext_pl_tlast_1 : std_logic:='0';
	signal ext_pl_tuser_1 : std_logic_vector(2 downto 0) := (others => '0');
    signal ext_pl_rdata_1 : std_logic_vector(7 downto 0);
	signal ext_pl_rvalid_1 : std_logic;
	signal ext_pl_rready_1 : std_logic := '1';
	signal ext_pl_rlast_1 : std_logic;
	signal ext_pl_ruser_1 : std_logic_vector(2 downto 0) := (others => '0');

	-- signals after adapter:
	signal post_udp_adapter_axis : metric_axi_stream_t;
	signal post_udp_adapter_axis_tready : std_logic := '1';

	signal data_concentrator_input_vector : metric_axi_stream_array_t(0 downto 0);
	signal data_concentrator_ready_input_vector : std_logic_vector(0 downto 0);

	signal not_reset: STD_LOGIC;
	signal pll_locked : STD_LOGIC;

	signal interlock_0 : std_logic;
begin

	process(clk0)
	begin 
		if(rising_edge(clk0)) then 
			not_reset <= not pll_locked;
		end if;
	end process;


    socket_pll : CC_PLL
	generic map (
		REF_CLK         => "10.0",
		OUT_CLK         => "40.0",
		PERF_MD         => "SPEED",
		LOW_JITTER      => 1,
		CI_FILTER_CONST => 2,
		CP_FILTER_CONST => 4
	)
	port map (
		CLK_REF             => clk,
		USR_CLK_REF         => '0',
		CLK_FEEDBACK        => '0',
		USR_LOCKED_STDY_RST => '0',
		USR_PLL_LOCKED_STDY => open,
		USR_PLL_LOCKED      => pll_locked,
		CLK0                => clk0,
		CLK90               => open,
		CLK180              => open,
		CLK270              => open,
		CLK_REF_OUT         => open
	);
    
    tx_w5500_fsm : w5500_state_machine
		generic map(
    		socket_amount => 8, -- all 8 sockets open 
			DEFAULT_ROUTINE => "send_first",
			mac_address => x"D47F39AE92B1",
			source_ip_address => x"C0A80265", --local ip address   192 168 2 101
    		dest_ip_address => x"C0A8026A", --destination ip address  192 168 2 106
    		source_udp_port => x"2401", -- local udp port   9217
    		dest_udp_port => x"2401" --destination udp port   9217
  		)
        port map(
            clk => clk0,
            reset => not_reset,
            spi_busy => spi_busy_0,
            tdata => tdata_0,  
            tvalid => tvalid_0,
            tready => tready_0,
            tlast => tlast_0,
            rdata => rdata_0,  
            rvalid => rvalid_0,
            rready => rready_0,
            rlast => rlast_0,
            ext_pl_tdata => ext_pl_tdata_0,
            ext_pl_tready => ext_pl_tready_0,
            ext_pl_tvalid => ext_pl_tvalid_0,
            ext_pl_tlast => ext_pl_tlast_0,
			ext_pl_tuser => ext_pl_tuser_0,
            ext_pl_rdata => ext_pl_rdata_0,
            ext_pl_rready => ext_pl_rready_0,
            ext_pl_rvalid => ext_pl_rvalid_0,
            ext_pl_rlast => ext_pl_rlast_0,
			ext_pl_ruser => ext_pl_ruser_0
			);

	    rx_w5500_fsm : w5500_state_machine
		generic map(
    		socket_amount => 8, -- all 8 sockets to be opened
			DEFAULT_ROUTINE => "receive_first",
			mac_address => x"D47F39AE92B2",
			source_ip_address => x"C0A80264", --local ip address   192 168 2 100
    		dest_ip_address => x"C0A8026A", --destination ip address  192 168 2 106
    		source_udp_port => x"2401", -- local udp port   9217
    		dest_udp_port => x"2401" --destination udp port   9217
  		)
        port map(
            clk => clk0,
            reset => not_reset,
            spi_busy => spi_busy_1,
            tdata => tdata_1,  
            tvalid => tvalid_1,
            tready => tready_1,
            tlast => tlast_1,
            rdata => rdata_1,  
            rvalid => rvalid_1,
            rready => rready_1,
            rlast => rlast_1,
            ext_pl_tdata => ext_pl_tdata_1,
            ext_pl_tready => ext_pl_tready_1,
            ext_pl_tvalid => ext_pl_tvalid_1,
            ext_pl_tlast => ext_pl_tlast_1,
			ext_pl_tuser => ext_pl_tuser_1,
            ext_pl_rdata => ext_pl_rdata_1,
            ext_pl_rready => ext_pl_rready_1,
            ext_pl_rvalid => ext_pl_rvalid_1,
            ext_pl_rlast => ext_pl_rlast_1,
			ext_pl_ruser => ext_pl_ruser_1
			);


    -- Instantiate the transceive_unit
    tx_spi_master : spi_master
        port map(
            clk => clk0,
			reset => not_reset,
			mosi => mosi_0,
			miso => miso_0,
			sclk => sclk_0,
			cs => cs_0,    
            tdata => tdata_0,
		    rdata => rdata_0,
		    spi_busy => spi_busy_0,
		    tvalid => tvalid_0,
		    tready => tready_0,
		    tlast => tlast_0,
		    rvalid => rvalid_0,
		    rready => rready_0,
		    rlast => rlast_0
		    );

	rx_spi_master : spi_master
        port map(
            clk => clk0,
			reset => not_reset,
			mosi => mosi_1,
			miso => miso_1,
			sclk => sclk_1,
			cs => cs_1,    
            tdata => tdata_1,
		    rdata => rdata_1,
		    spi_busy => spi_busy_1,
		    tvalid => tvalid_1,
		    tready => tready_1,
		    tlast => tlast_1,
		    rvalid => rvalid_1,
		    rready => rready_1,
		    rlast => rlast_1
		    );
	
	unit_udp_packet_adapter : udp_packet_adapter
     port map(
        clk => clk0,
        reset => not_reset,
        rdata => ext_pl_rdata_1,
        rlast => ext_pl_rlast_1,
        rvalid => ext_pl_rvalid_1,
        rready => ext_pl_rready_1,
        ruser => ext_pl_ruser_1,
        tdata => post_udp_adapter_axis.tdata,
        tuser => post_udp_adapter_axis.tuser,
        tready => post_udp_adapter_axis_tready,
        tvalid => post_udp_adapter_axis.tvalid,
        tlast => post_udp_adapter_axis.tlast
    );
	

	data_concentrator_input_vector(0) <= post_udp_adapter_axis;
	post_udp_adapter_axis_tready <= data_concentrator_ready_input_vector(0);

    -- Instantiate the ext_data_handler
    dataconcentrator : data_concentrator
		generic map(
        	input_channel_amount => 1
    	)
        port map(
            clk => clk0,
            reset => not_reset,
            tdata => ext_pl_tdata_0,
            tvalid => ext_pl_tvalid_0,
            tlast => ext_pl_tlast_0,
            tready => ext_pl_tready_0,
			tuser => ext_pl_tuser_0,
            s_axis => data_concentrator_input_vector,            
            s_axis_ready => data_concentrator_ready_input_vector,
            interlock => interlock_0,
            deassert_interlock => not button,
			ext_interlock_source => '0'
        );

		-- HANDLING THE TWO W5500s tasks, TX and RX
		
		--The TX W5500 is only responsible for sending, if it should receive something anyways, we are always ready to read but don't process
		ext_pl_rready_0 <= '1';

		-- The RX w5500 never has something to send, which is why tvalid / tlast are always low
		ext_pl_tvalid_1 <= '0';
		ext_pl_tlast_1 <= '0';

		onboard_leds(0) <= interlock_0; -- onboard LEDs are default HIGH, means a triggered interlock turns the onboard LED off
		onboard_leds(3 downto 1) <= not ext_pl_ruser_1;
		onboard_leds(6 downto 4) <= not ext_pl_tuser_0;
		onboard_leds(7) <= '1'; -- keepin it '1' so it doesn't glow on board

end Behavioral;
