library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.metric_axi_stream_pkg.all;

entity interlock_glitch_filter is
    port (
        clk         : in  STD_LOGIC;
        reset       : in  STD_LOGIC;
        interlock_in : in STD_LOGIC;
        interlock_out  : out STD_LOGIC
    );
end interlock_glitch_filter;

architecture Behavioral of interlock_glitch_filter is

signal interlock_signal_shift_reg : std_logic_vector(3 downto 0) := "0000";

begin
    process(clk, reset) 
    begin 
        if(rising_edge(clk)) then 
            if(reset = '1') then 
                interlock_out <= '0';
                interlock_signal_shift_reg <= "0000";
            else 
                interlock_signal_shift_reg <= interlock_signal_shift_reg(2 downto 0) & interlock_in;
                
                if(interlock_signal_shift_reg = "1111") then
                    interlock_out <= '1';
                elsif(interlock_signal_shift_reg = "0000") then
                    interlock_out <= '0';
                end if;
            end if;
        end if;
    end process;

end Behavioral;