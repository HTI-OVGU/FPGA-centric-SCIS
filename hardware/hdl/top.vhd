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

		-- CAN bus interface. can_rx <- transceiver RXD (or the remote controller's TX
		-- on the transceiver-less bench link); can_tx -> transceiver TXD, or straight
		-- onto the shared bus wire. See the wiring-configuration note at can_source.
		can_rx : in std_logic := '1';
		can_tx : out std_logic;

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

	-- GateMate configuration-engine reset. USR_RSTN is driven LOW by the config
	-- engine during configuration and released HIGH once the fabric is configured.
	-- Unlike a FF power-up value it is deterministic every boot, so it is the only
	-- sound anchor for a power-on reset on this device (there is no global GSR here).
	component CC_USR_RSTN is
		port (
			USR_RSTN : out std_logic
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
			s_axis		: in metric_axi_stream_array_t(input_channel_amount-1 downto 0);
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

	-- CAN path: one self-contained can_metric_source block -> metric stream + LED status
	signal post_can_adapter_axis : metric_axi_stream_t;
	signal post_can_adapter_axis_tready : std_logic := '1';
	signal can_rx_act : std_logic; -- pulse-stretched rx activity (for LED D8)

	-- TX-activity LED stretch: raw ext_pl_tuser_0 only holds during a TX burst and
	-- collapses between packets, so the TX socket-number LEDs flicker. Latch the
	-- socket # on each TX beat and hold it lit for TX_STRETCH_CLKS so it stays steady.
	constant TX_STRETCH_CLKS : natural := 6_000_000;  -- ~0.2 s @ 30 MHz clk0
	signal tx_user_held : std_logic_vector(2 downto 0) := (others => '0');
	signal tx_stretch   : natural range 0 to TX_STRETCH_CLKS := 0;

	-- two metric input channels: (0) = W5500/UDP, (1) = CAN
	signal data_concentrator_input_vector : metric_axi_stream_array_t(1 downto 0);
	signal data_concentrator_ready_input_vector : std_logic_vector(1 downto 0);

	signal reset: STD_LOGIC := '1';        -- start asserted; released only by the POR below
	signal pll_locked : STD_LOGIC;

	-- Power-on reset generator state. usr_rstn comes from the config engine and is
	-- the async-assert source (deterministic every boot). por_cnt then holds reset
	-- asserted for a window AFTER the PLL locks so every synchronous-reset FF is
	-- clocked at least once with reset='1' regardless of its INIT.
	signal usr_rstn : std_logic;
	signal por_cnt  : unsigned(3 downto 0) := (others => '0');

	signal interlock_0 : std_logic;
begin

	-- Deterministic power-on reset. GateMate has no global GSR, and ~2/3 of the FFs
	-- come up INIT=x, so "reset <= not pll_locked" alone is unreliable: if clk0 does
	-- not toggle before lock, that reset never actually asserts and the synchronous
	-- resets never fire -> place-and-route-dependent startup. Anchor reset to the
	-- config engine's USR_RSTN (async assert, no clock needed) and hold it through
	-- PLL lock + a short counted window, then release synchronously.
	u_usr_rstn : CC_USR_RSTN
		port map (
			USR_RSTN => usr_rstn
		);

	por_proc : process (clk0, usr_rstn)
	begin
		if usr_rstn = '0' then                 -- async assert straight out of configuration
			por_cnt <= (others => '0');
			reset   <= '1';
		elsif rising_edge(clk0) then
			if pll_locked = '0' then           -- hold in reset until the PLL is locked
				por_cnt <= (others => '0');
				reset   <= '1';
			elsif por_cnt /= "1111" then       -- then keep reset asserted for 16 more clk0 edges
				por_cnt <= por_cnt + 1;
				reset   <= '1';
			else
				reset   <= '0';                -- fully released; run normally
			end if;
		end if;
	end process por_proc;


    socket_pll : CC_PLL
	generic map (
		REF_CLK         => "10.0",
		OUT_CLK         => "30.0",
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
            reset => reset,
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
            reset => reset,
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
			reset => reset,
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
			reset => reset,
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
        reset => reset,
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

	-- ---- CAN bus interface: one self-contained can_metric_source -> DC channel 1 ----
	-- Active node (ACK_DRIVE=true): the FPGA drives a dominant ACK on can_tx for every
	-- accepted frame, so the remote controller sees its frames acknowledged instead of
	-- retransmitting them until it goes error-passive. All CAN internals live in the block.
	--
	-- clk0 = 30 MHz from the CC_PLL (ClockFrequencyHz must track OUT_CLK);
	-- CLKS_PER_BIT=0 derives 125 kbps (CPB = 30 MHz / 125 kHz = 240, 75% sample point).
	--
	-- THREE VALID WIRING CONFIGURATIONS -- pick exactly one:
	--
	--  (A) two wires, no transceiver          ECHO_RX => true,  TX_OPEN_DRAIN => false
	--      STM32 PD1 -> PMOD B pin 7, PMOD B pin 8 -> STM32 PD0. can_tx mirrors can_rx so
	--      the STM32's bit monitoring sees its own bits come back; without the mirror it
	--      bit-errors on the SOF of every frame and goes bus-off. can_tx is then a
	--      plain push-pull output (the CCF line is the same either way).
	--
	--  (B) one shared wire + pull-up, no transceiver   <-- CURRENT CONFIGURATION
	--                                          ECHO_RX => false, TX_OPEN_DRAIN => true
	--      PMOD B pins 7 and 8, STM32 PD0 and PD1 all on one node with a 1k-2.2k pull-up
	--      to 3V3; PD1 open-drain (GPIO_MODE_AF_OD). A real wired-AND bus, so this is the
	--      faithful rehearsal for (C): identical RTL config apart from the pad drive
	--      style. ECHO_RX MUST be false -- mirroring a node back onto itself is positive
	--      feedback that latches the bus dominant.
	--
	--  (C) TJA1051T/3 transceivers, real bus   ECHO_RX => false, TX_OPEN_DRAIN => false
	--      RXD -> PMOD B pin 7, PMOD B pin 8 -> TXD, push-pull. Same reason ECHO_RX must
	--      be false: driving TXD from RXD through a transceiver latches the bus dominant.
	--
	-- Pin assignment and the matching CCF drive style live in constraints_dc_and_w5500.ccf.
	can_source : entity work.can_metric_source(rtl)
	generic map(
		ClockFrequencyHz => 30_000_000,
		CLKS_PER_BIT     => 0,
		ACK_DRIVE        => true,
		ECHO_RX          => true, -- config (B): shared-wire wired-AND rehearsal
		TX_OPEN_DRAIN    => false,  -- config (B)
		CAN_TUSER        => "001"
	)
	port map(
		clk           => clk0,
		reset         => reset,
		can_rx        => can_rx,
		m_axis        => post_can_adapter_axis,
		m_axis_tready => post_can_adapter_axis_tready,
		rx_id_low     => open,
		rx_activity   => can_rx_act,
		overrun       => open,
		can_tx        => can_tx
	);

	data_concentrator_input_vector(1) <= post_can_adapter_axis;
	post_can_adapter_axis_tready <= data_concentrator_ready_input_vector(1);

    -- Instantiate the ext_data_handler
    dataconcentrator : data_concentrator
		generic map(
        	input_channel_amount => 2
    	)
        port map(
            clk => clk0,
            reset => reset,
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

	-- Pulse-stretch the TX socket number so the TX-activity LEDs don't flicker between
	-- packets (mirrors the CAN RX activity stretch inside can_metric_source).
	tx_activity_stretch : process (clk0)
	begin
		if rising_edge(clk0) then
			if reset = '1' then
				tx_user_held <= (others => '0');
				tx_stretch   <= 0;
			elsif ext_pl_tvalid_0 = '1' and ext_pl_tready_0 = '1' then
				tx_user_held <= ext_pl_tuser_0;         -- latch socket # on each TX beat
				tx_stretch   <= TX_STRETCH_CLKS;        -- (re)arm the hold timer
			elsif tx_stretch > 0 then
				tx_stretch <= tx_stretch - 1;           -- hold the last value while lit
			else
				tx_user_held <= (others => '0');        -- fall dark after the hold expires
			end if;
		end if;
	end process tx_activity_stretch;

		onboard_leds(0) <= interlock_0; -- onboard LEDs are default HIGH, means a triggered interlock turns the onboard LED off
		onboard_leds(3 downto 1) <= not ext_pl_ruser_1;
		onboard_leds(6 downto 4) <= not tx_user_held; -- pulse-stretched TX socket #
		onboard_leds(7) <= not can_rx_act; -- D8 blinks (active-low) on received CAN frames

end Behavioral;
