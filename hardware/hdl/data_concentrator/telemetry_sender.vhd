library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.metric_axi_stream_pkg.all;

entity telemetry_sender is
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
        almost_full_vector : in STD_LOGIC_VECTOR(7 downto 0) := x"00"
    );
end telemetry_sender;

architecture Behavioral of telemetry_sender is

type interlock_alert_sender_state_type is (IDLE, PASSTHROUGH, SEND_INTERLOCK_ALERT, SEND_ALMOST_FULL_ALERT);
signal alert_sender_state : interlock_alert_sender_state_type := PASSTHROUGH;

type interlock_byte_array is array (0 to 8) of STD_LOGIC_VECTOR(7 downto 0);
constant INTERLOCK_ALERT_SEQUENCE : interlock_byte_array := (
        x"49", x"4E", x"54", x"45", x"52", x"4C", x"4F" , x"43", x"4B"); -- INTERLOCK   in ASCII

type almost_full_byte_array is array (0 to 9) of STD_LOGIC_VECTOR(7 downto 0);
constant ALMOST_FULL_ALERT_SEQUENCE : almost_full_byte_array := (
        x"41", x"4C", x"4D", x"4F", x"53", x"54", x"46" , x"55", x"4C", x"4C");

        signal alert_sequence_counter : integer := 0;


signal prev_interlock_signal : std_logic := '0'; -- this is introduced, because the interlock ASCII sequence should only be sent once.   
-- Once the ALERT SEQUENCE is sent, the metrics should be sent further to the metric server. 
-- since the Interlock SIGNAL is latching, until manual deassertion, it is checked for rising edge of the interlock signal
signal prev_almost_full_vector : std_logic_vector(7 downto 0) := x"00";

begin

    process (clk, reset) -- axi interface process synchronous
    begin
        if(rising_edge(clk)) then
            if(reset = '1') then
                alert_sender_state <= IDLE;
                alert_sequence_counter <= 0;
            else
                case alert_sender_state is  
                    when IDLE => 

                        if(prev_interlock_signal = '0' and interlock = '1') then 
                            alert_sender_state <= SEND_INTERLOCK_ALERT;

                        elsif (not almost_full_vector = x"00" and prev_almost_full_vector = x"00") then -- detect any rising edge 
                            alert_sender_state <= SEND_ALMOST_FULL_ALERT;
                        
                        elsif (s_axis_valid = '1') then 
                            alert_sender_state <= PASSTHROUGH;
                        end if;

                        alert_sequence_counter <= 0;

                        prev_interlock_signal <= interlock;
                        prev_almost_full_vector <= almost_full_vector;

                    when PASSTHROUGH => 
                        -- tready is handled async in second process

                        if(s_axis_last = '1' and s_axis_valid = '1' and m_axis_ready = '1') then 
                            alert_sender_state <= IDLE;
                        end if;

                    when SEND_INTERLOCK_ALERT =>

                        if m_axis_ready = '1' then 
                            if(alert_sequence_counter = 8) then 
                                alert_sender_state <= IDLE;
                            else
                                alert_sequence_counter <= alert_sequence_counter + 1;
                            end if;
                        end if;
                    
                    when SEND_ALMOST_FULL_ALERT =>
                        if m_axis_ready = '1' then 
                            if(alert_sequence_counter = 9) then 
                                alert_sender_state <= IDLE;
                            else
                                alert_sequence_counter <= alert_sequence_counter + 1;
                            end if;
                        end if;

                end case;
            end if; 
        end if;
    end process;

    --tready process async
    process (clk, reset) 
    begin 
        if(reset = '1') then 
            s_axis_ready <= '0';
        else   
            case alert_sender_state is   
                when SEND_INTERLOCK_ALERT => s_axis_ready <= '0';
                when SEND_ALMOST_FULL_ALERT => s_axis_ready <= '0';
                when others =>  s_axis_ready <= m_axis_ready;
            end case;
        end if;
    end process;

    -- async process writing interlock_Sequence or PASSTHROUGH
    process (reset, alert_sender_state)
    begin 
        if reset = '1' then 
            m_axis_data <= x"00";
            m_axis_valid <= '0';
            m_axis_user <= "000"; -- highest priority
            m_axis_last <= '0';
        else 
            case alert_sender_state is 
                when SEND_INTERLOCK_ALERT => 
                    m_axis_data <= INTERLOCK_ALERT_SEQUENCE(alert_sequence_counter);
                    m_axis_valid <= '1';
                    m_axis_user <= "000"; -- highest priority

                    if(alert_sequence_counter = 8) then 
                        m_axis_last <= '1';
                    else 
                        m_axis_last <= '0';
                    end if;

                when SEND_ALMOST_FULL_ALERT => 
                    m_axis_data <= ALMOST_FULL_ALERT_SEQUENCE(alert_sequence_counter);
                    m_axis_valid <= '1';
                    m_axis_user <= "111"; -- lowest priority

                    if(alert_sequence_counter = 9) then 
                        m_axis_last <= '1';
                    else 
                        m_axis_last <= '0';
                    end if;

                when IDLE => 

                    m_axis_data <= x"00";
                    m_axis_valid <= '0';
                    m_axis_user <= "000"; 
                    m_axis_last <= '0';
                
                when PASSTHROUGH => 
                    m_axis_data <= s_axis_data;
                    m_axis_user <= s_axis_user;
                    m_axis_valid <= s_axis_valid;
                    m_axis_last <= s_axis_last;
            end case;
        end if;
    end process;

end Behavioral;