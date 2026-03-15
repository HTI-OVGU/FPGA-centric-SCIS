library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity tb_top is
end tb_top;

architecture sim of tb_top is
    -- Component under test
    component top_for_tb
        port (
            clk   : in  std_logic;
            reset : in  std_logic;
            mosi  : out std_logic;
            miso  : in  std_logic;
            sclk  : out std_logic;
            cs    : out std_logic;
            led0  : out std_logic;
            led1  : out std_logic;
            led2  : out std_logic;
            led3  : out std_logic;
            led4  : out std_logic;
            led5  : out std_logic;
            led6  : out std_logic;
            led7  : out std_logic
        );
    end component;

    -- Testbench signals
    signal clk   : std_logic := '0';
    signal reset : std_logic := '0';
    signal mosi  : std_logic;
    signal miso  : std_logic := '0'; -- feed test values later
    signal sclk  : std_logic;
    signal cs    : std_logic;
    signal leds  : std_logic_vector(7 downto 0);



begin
    -- Clock generation (100 MHz -> 10 ns period)
    clk_process : process
    begin
        while true loop
            clk <= '0';
            wait for 5 ns;
            clk <= '1';
            wait for 5 ns;
        end loop;
    end process;

    -- Reset generation
    process
    begin
        reset <= '1';
        wait for 100 ns;
        reset <= '0';
        wait;
    end process;

    --miso dummy write like w5500 would
    miso_process: process
        type t_data_array is array(0 to 3) of std_logic_vector(7 downto 0);
        constant data_seq : t_data_array := (x"01", x"02", x"03", x"00");
        variable byte_index : integer := 0;
        variable bit_index : integer := 7;
        variable shift_reg : std_logic_vector(7 downto 0);
    begin
        wait until cs = '0'; -- wait for transaction start
        byte_index := 0;
        shift_reg := data_seq(byte_index);
        bit_index := 7;

        while cs = '0' loop
            miso <= shift_reg(bit_index);
            bit_index := bit_index - 1;

            if bit_index < 0 then
                byte_index := (byte_index + 1) mod 4; -- loop sequence
                shift_reg := data_seq(byte_index);
                bit_index := 7;
            end if;
            wait until falling_edge(sclk);
        end loop;

        miso <= '0'; -- idle after CS goes high
    end process;


    -- DUT instantiation
    uut: top_for_tb
        port map(
            clk   => clk,
            reset => reset,
            mosi  => mosi,
            miso  => miso,
            sclk  => sclk,
            cs    => cs,
            led0  => leds(0),
            led1  => leds(1),
            led2  => leds(2),
            led3  => leds(3),
            led4  => leds(4),
            led5  => leds(5),
            led6  => leds(6),
            led7  => leds(7)
        );

end sim;
