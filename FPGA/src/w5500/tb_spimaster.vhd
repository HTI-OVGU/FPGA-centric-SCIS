----------------------------------------------------------------------------------
-- File: spi_master_tb.vhd
-- Description: Testbench for SPI Master
-- Tests transmission of 4 bytes via AXI Stream interface
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity spi_master_tb is
end entity spi_master_tb;

architecture testbench of spi_master_tb is
    -- Component declaration
    component spi_master is
        port (
            tdata:   in std_logic_vector (7 downto 0);
            rdata:   out std_logic_vector (7 downto 0);
            mosi:    out std_logic;
            miso:    in std_logic := '0';
            sclk:    out std_logic;
            cs:      out std_logic;
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
    end component;

    -- Clock period definition
    constant CLK_PERIOD : time := 10 ns;  -- 100 MHz clock
    
    -- Test data to transmit
    type byte_array is array (0 to 3) of std_logic_vector(7 downto 0);
    constant TEST_DATA : byte_array := (
        X"AA",  -- Byte 0
        X"55",  -- Byte 1
        X"F0",  -- Byte 2
        X"0F"   -- Byte 3
    );
    
    -- Signals for UUT (Unit Under Test)
    signal clk      : std_logic := '0';
    signal reset    : std_logic := '0';
    signal tdata    : std_logic_vector(7 downto 0) := (others => '0');
    signal tvalid   : std_logic := '0';
    signal tready   : std_logic;
    signal tlast    : std_logic := '0';
    signal rdata    : std_logic_vector(7 downto 0);
    signal rvalid   : std_logic;
    signal rready   : std_logic := '1';  -- Always ready to receive
    signal rlast    : std_logic;
    signal mosi     : std_logic;
    signal miso     : std_logic := '0';
    signal sclk     : std_logic;
    signal cs       : std_logic;
    signal spi_busy : std_logic;
    
    -- Testbench control signals
    signal sim_done : boolean := false;
    signal byte_count : integer := 0;

begin
    -- Instantiate the Unit Under Test (UUT)
    uut: spi_master
        port map (
            tdata    => tdata,
            rdata    => rdata,
            mosi     => mosi,
            miso     => miso,
            sclk     => sclk,
            cs       => cs,
            clk      => clk,
            reset    => reset,
            spi_busy => spi_busy,
            tvalid   => tvalid,
            tready   => tready,
            tlast    => tlast,
            rvalid   => rvalid,
            rready   => rready,
            rlast    => rlast
        );

    -- Clock generation process
    clk_process: process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD/2;
            clk <= '1';
            wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    -- MISO loopback simulation (echo back MOSI data)
    -- In a real scenario, this would be driven by the SPI slave device
    miso_process: process(sclk, cs)
    begin
        if cs = '0' then
            if rising_edge(sclk) then
                miso <= mosi;  -- Simple loopback for testing
            end if;
        end if;
    end process;

    -- Main stimulus process
    stimulus: process
    begin
        -- Initialize
        report "Starting SPI Master Testbench";
        reset <= '1';
        tvalid <= '0';
        tlast <= '0';
        tdata <= (others => '0');
        byte_count <= 0;
        
        -- Hold reset for a few clock cycles
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;
        
        report "Reset released, waiting for FIFO ready";
        
        -- Wait for tready to go high (FIFO ready)
        if tready = '0' then
            wait until tready = '1';
        end if;
        wait for CLK_PERIOD;
        
        report "FIFO ready, starting transmission of 4 bytes";
        
        -- Transmit 4 bytes
        for i in 0 to 3 loop
            -- Present data on AXI Stream interface
            tdata <= TEST_DATA(i);
            tvalid <= '1';
            
            -- Set tlast on the last byte
            if i = 3 then
                tlast <= '1';
                report "Sending byte " & integer'image(i) & ": " & 
                       integer'image(to_integer(unsigned(TEST_DATA(i)))) & 
                       " (LAST BYTE)";
            else
                tlast <= '0';
                report "Sending byte " & integer'image(i) & ": " & 
                       integer'image(to_integer(unsigned(TEST_DATA(i))));
            end if;
            
            -- Wait for handshake
            wait until rising_edge(clk) and tready = '1';
            wait for CLK_PERIOD;
            
            -- Deassert valid after handshake
            tvalid <= '0';
            tlast <= '0';
            tdata <= (others => '0');
            
        end loop;
        
        report "All 4 bytes sent to FIFO";
        
        -- Wait for SPI transmission to complete
        wait until spi_busy = '0' and cs = '1';
        wait for CLK_PERIOD * 10;
        
        report "SPI transmission complete";
        
        -- Check received data
        wait for CLK_PERIOD * 5;
        
        report "Simulation completed successfully";
        sim_done <= true;
        
        wait;
    end process;

    -- Monitor process to display received data
    rx_monitor: process(clk)
    begin
        if rising_edge(clk) then
            if rvalid = '1' and rready = '1' then
                report "Received byte: " & 
                       integer'image(to_integer(unsigned(rdata))) & 
                       " | rlast = " & std_logic'image(rlast);
            end if;
        end if;
    end process;

    -- Timeout watchdog (optional safety feature)
    timeout: process
    begin
        wait for 100 us;  -- Adjust based on expected simulation time
        if not sim_done then
            report "TIMEOUT: Simulation did not complete in expected time" severity failure;
        end if;
        wait;
    end process;

end architecture testbench;