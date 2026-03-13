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

entity top_w5500 is
    	port (
		-- This is the main clock from the board's oscillator (e.g., 100 MHz)
		clk:  in  std_logic;
		button: in  std_logic := '0';
		
		-- SPI Interface
		mosi: out std_logic;
		miso: in  std_logic := '0';
		sclk: out std_logic;
		cs:   out std_logic := '1'
		);
end top_w5500;

architecture Behavioral of top_w5500 is

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

    component spi_master
        port (
			clk:    in std_logic;
			reset:  in std_logic;
			mosi:  out std_logic;
			miso:   in std_logic;
			sclk:  out std_logic;
			cs:    out std_logic;
            tdata:   in std_logic_vector (7 downto 0); -- data to send
            TVALID:    in std_logic;
		    TREADY :   out std_logic;
		    tlast : in std_logic;
		    rdata:  out std_logic_vector (7 downto 0); -- data received
		    RVALID :   out std_logic;
		    RREADY :   in std_logic;
		    rlast : out std_logic;
		    spi_busy: out std_logic
		);
	end component;
	
	component w5500_state_machine
		generic (
    	socket_amount : integer; -- all 8 sockets to be opened
		DEFAULT_ROUTINE : string
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
    
    component ext_data_handler
        port(
            clk         : in  STD_LOGIC;
            rst         : in  STD_LOGIC;
            tdata       : out STD_LOGIC_VECTOR(7 downto 0);
            tvalid      : out STD_LOGIC;
            tlast       : out STD_LOGIC;
            tready      : in  STD_LOGIC;
			tuser 		: out STD_LOGIC_VECTOR(2 downto 0);
            rdata       : in  STD_LOGIC_VECTOR(7 downto 0);
            rlast       : in  STD_LOGIC;
            rvalid      : in  STD_LOGIC;
            rready      : out STD_LOGIC;
			ruser 		: in  STD_LOGIC_VECTOR(2 downto 0)
        );
    end component;

--Outputs
    signal spi_busy: std_logic;
    	
-- w5500 data signals
    signal tdata : std_logic_vector(7 downto 0) := (others => '0');
    signal rdata : std_logic_vector(7 downto 0) := (others => '0');
    signal TVALID, RVALID, TREADY, RREADY, rlast, tlast : std_logic;
	
    
    -- Hardware IO simulation signals
    signal ext_pl_tdata : std_logic_vector(7 downto 0);
	signal ext_pl_tvalid : std_logic := '1';
	signal ext_pl_tready : std_logic;
	signal ext_pl_tlast : std_logic:='0';
    signal ext_pl_rdata : std_logic_vector(7 downto 0);
	signal ext_pl_rvalid : std_logic;
	signal ext_pl_rready : std_logic := '1';
	signal ext_pl_rlast : std_logic;
	signal ext_pl_tuser : std_logic_vector(2 downto 0) := (others => '0');
	signal ext_pl_ruser : std_logic_vector(2 downto 0) := (others => '0');

	signal reset: STD_LOGIC;
	signal pll_locked : STD_LOGIC;

    -- REMOVED: The clk_out signal is no longer needed.	


begin
    
	reset <= not pll_locked;

    socket_pll : CC_PLL
	generic map (
		REF_CLK         => "10.0",
		OUT_CLK         => "40.0",
		PERF_MD         => "ECONOMY",
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
    
    -- Instantiate the w5500_state_machine
    spi_m : w5500_state_machine
		generic map(
    		socket_amount => 1, -- all 8 sockets to be opened
			DEFAULT_ROUTINE => "receive_first"
  		)
        port map(
            -- CHANGED: Connected directly to the top-level clock and reset
            clk => clk0,
            reset => reset,
            spi_busy => spi_busy,
            tdata => tdata,  
            tvalid => tvalid,
            tready => tready,
            tlast => tlast,
            rdata => rdata,  
            rvalid => rvalid,
            rready => rready,
            rlast => rlast,
            ext_pl_tdata => ext_pl_tdata,
            ext_pl_tready => ext_pl_tready,
            ext_pl_tvalid => ext_pl_tvalid,
            ext_pl_tlast => ext_pl_tlast,
			ext_pl_tuser => ext_pl_tuser,
            ext_pl_rdata => ext_pl_rdata,
            ext_pl_rready => ext_pl_rready,
            ext_pl_rvalid => ext_pl_rvalid,
            ext_pl_rlast => ext_pl_rlast,
			ext_pl_ruser => ext_pl_ruser
		);

    -- Instantiate the transceive_unit
    spi_master_unit : spi_master
        port map(
            -- CHANGED: Connected directly to the top-level clock and reset
            clk => clk0,
			reset => reset,
			mosi => mosi,
			miso => miso,
			sclk => sclk,
			cs => cs,    
            tdata => tdata,
		    rdata => rdata,
		    spi_busy => spi_busy,
		    TVALID => TVALID,
		    TREADY => TREADY,
		    tlast => tlast,
		    RVALID => RVALID,
		    RREADY => RREADY,
		    rlast => rlast
		    );

    -- Instantiate the ext_data_handler
    extdatahandler : ext_data_handler
        port map(
            -- CHANGED: Connected directly to the top-level clock and reset
            clk => clk0,
            rst => reset,
            tdata => ext_pl_tdata,
            tvalid => ext_pl_tvalid,
            tlast => ext_pl_tlast,
            tready => ext_pl_tready,
			tuser => ext_pl_tuser,
            rdata => ext_pl_rdata,
            rvalid => ext_pl_rvalid,
            rlast => ext_pl_rlast,
            rready => ext_pl_rready,
			ruser => ext_pl_ruser   
        );

end Behavioral;
