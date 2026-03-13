----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 15.12.2024 10:35:11
-- Design Name: 
-- Module Name: ext_data_handler - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity ext_data_handler is
    generic (
        TEST_MODE : integer := 1 -- 0 Tests package transmission, 1 is the loopback test, 2 for large packet transmission
    );
    port (
        clk         : in  STD_LOGIC;
        rst         : in  STD_LOGIC;
        tdata       : out STD_LOGIC_VECTOR(7 downto 0);
        tvalid      : out STD_LOGIC;
        tlast       : out STD_LOGIC;
        tready      : in  STD_LOGIC;
        tuser       : out STD_LOGIC_VECTOR(2 downto 0);
        rdata       : in  STD_LOGIC_VECTOR(7 downto 0);
        rlast       : in  STD_LOGIC;
        rvalid      : in  STD_LOGIC;
        rready      : out STD_LOGIC;
        ruser       : in  STD_LOGIC_VECTOR(2 downto 0)
    );
end ext_data_handler;

architecture Behavioral of ext_data_handler is

    -- States for FSM
    type state_type is (IDLE, RECEIVE_HEADER, RECEIVE_DATA, SEND_DATA);
    signal current_state, next_state : state_type := IDLE;

    signal not_reset : std_logic := '0'; -- Simulation-only initialization

    signal rdata_buffer    : std_logic_vector(7 downto 0);
    signal rvalid_buffer   : std_logic := '0';
    signal rready_buffer   : std_logic := '1';
    signal rlast_buffer    : std_logic := '0';
    
    signal tdata_buffer    : std_logic_vector(7 downto 0);
    signal tvalid_buffer   : std_logic := '0';
    signal tready_buffer   : std_logic := '1';
    signal tlast_buffer    : std_logic := '0';
    
    signal header_byte_counter : integer := 0;


    component axis_data_fifo is
         port (
            i_rst_sync     : in  std_logic;
            i_clk          : in  std_logic;
            s_axis_tvalid  : in  std_logic;
            s_axis_tdata   : in  std_logic_vector(7 downto 0);
            s_axis_tlast   : in  std_logic;
            s_axis_tready  : out std_logic;
            m_axis_tvalid  : out std_logic;
            m_axis_tdata   : out std_logic_vector(7 downto 0);
            m_axis_tlast   : out std_logic;
            m_axis_tready  : in  std_logic
         );
    end component;
    

 
    -- signals for testmode 0 and 2

    signal counter      : integer := 0;
    signal byte_index   : integer := 0;
    signal packet_count : integer := 0;  -- Track the number of packets sent
    signal sending      : boolean := false;
    constant INTERVAL   : integer := 187500; -- Interval between transmissions
    constant DATA_SIZE : integer := 255;
    signal current_socket_counter : integer := 0;



begin

--    not_reset <= not rst;

    loop_back_buffer_fifo : axis_data_fifo
        port map (
            s_axis_tdata  => rdata_buffer,
            s_axis_tready => rready_buffer,
            s_axis_tvalid => rvalid_buffer,
            s_axis_tlast  => rlast_buffer,
            i_clk         => clk,
            i_rst_sync    => rst,
            m_axis_tdata  => tdata_buffer,
            m_axis_tready => tready_buffer,
            m_axis_tvalid => tvalid_buffer,
            m_axis_tlast  => tlast_buffer 
        );


    -- Test Mode 
GEN_TEST_0: if TEST_MODE = 0 generate
    
 process(clk, rst)
    begin
    
    rready <= '1'; --this accepts all incoming received data from the W5500, but does nothing with it
    
    if rising_edge(clk) then
        if rst = '1' then
            counter      <= 0;
            byte_index   <= 0;
            current_socket_counter <= 0;
            packet_count <= 0;
            sending      <= false;
            tdata        <= (others => '0');
            tvalid       <= '0';
            tlast <= '0';
        else
            if(sending = true) then
            -- this just send's the byte index
            tvalid <= '1';
            tlast <= '1';
            tdata <= std_logic_vector(to_unsigned(byte_index,8));
            tuser <= STD_LOGIC_VECTOR(to_unsigned(current_socket_counter,3));
            if(tready = '1') then
                tvalid <= '0';
                byte_index <= byte_index + 1;
                current_socket_counter <= current_socket_counter + 1;
                sending <= false;
            end if;            
        
        else --if sending = false
            tvalid <= '0';
            tlast <= '0';
            if(counter = INTERVAL - 1) then
                counter <= 0;
                sending <= true;
            else
                counter <= counter + 1; 
            end if;
        end if;
    end if;
    end if;
end process;


end generate GEN_TEST_0;

GEN_TEST_1: if TEST_MODE = 1 generate

tdata <= tdata_buffer;
tvalid <= tvalid_buffer;
tready_buffer <= tready;
tlast <= tlast_buffer;
tuser <= std_logic_vector(to_unsigned(current_socket_counter,3));

process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                -- Reset all signals and FSM
                current_state       <= IDLE;
                header_byte_counter <= 0;
                rvalid_buffer       <= '0';
                rready              <= '1';
            else
                case current_state is
                    when IDLE =>
                        -- Reset signals and wait for incoming data
                        rready        <= '1';
                        header_byte_counter <= 0;

                        if rvalid = '1' then
                            current_state <= RECEIVE_HEADER;
                            current_socket_counter <= to_integer(unsigned(ruser));
                        end if;
    
                    when RECEIVE_HEADER => 
                        rready <= '1';
                        -- Skip the first 8 bytes (DEST_IP, PORT, Length)
                        if (rvalid = '1') then 
                            if (header_byte_counter < 7) then  
                                header_byte_counter <= header_byte_counter + 1;
                                rvalid_buffer <= '0';
                                rlast_buffer <= '0';
                            else
                                -- Start receiving actual payload data
                                current_state <= RECEIVE_DATA;
                                
                                --in the clk cycle of the state switch, we can already receive the first byte
                                if (rvalid = '1') then
                                    rvalid_buffer <= '1';
                                    rdata_buffer  <= rdata;
                                    rlast_buffer  <= rlast;
                                else
                                    rvalid_buffer <= '0';
                                end if;
                                
                            end if;
                        end if;
                                               
                    when RECEIVE_DATA =>
                        -- Store data in the FIFO
                        if (rvalid = '1') then
                            rvalid_buffer <= '1';
                            rdata_buffer  <= rdata;
                            rlast_buffer  <= rlast;
                        else
                            rvalid_buffer <= '0';
                        end if;
                        
                        rready <= rready_buffer;
                        
                        -- Detect end of the packet
                        if rlast = '1' and rvalid = '1' then
                            current_state <= SEND_DATA;
                        end if;
                        
                    when SEND_DATA =>
                        -- Read from FIFO and send data

                        if (tlast_buffer = '1' and tvalid_buffer = '1' and tready = '1') then
                            -- Packet fully sent, go back to IDLE
                            current_state <= IDLE;
                        end if;

                        rready        <= '0';
                        rvalid_buffer <= '0';
                        rlast_buffer  <= '0';
                        
                end case;
            end if;
        end if;
    end process;

end generate GEN_TEST_1;

GEN_TEST_2: if TEST_MODE = 2 generate
    rready <= '1'; --accept everything, it's not processed though

    process(clk, rst)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                counter     <= 0;
                byte_index  <= 0;
                sending     <= false;
                tdata       <= (others => '0');
                tvalid      <= '0';
                tlast       <= '0';
            else
                if sending then
                    -- Assign tdata every cycle while sending
                    tdata  <= std_logic_vector(to_unsigned(byte_index, 8));
                    tvalid <= '1';

                    if byte_index = DATA_SIZE - 1 then  
                        tlast   <= '1';      -- Mark last byte
                        sending <= false;    -- Stop sending
                        byte_index <= 0;     -- Reset index for next burst
                    else
                        tlast <= '0';
                        if tready = '1' then
                            byte_index <= byte_index + 1; -- Increment on valid transmission
                        end if;
                    end if;
                else
                    -- Wait for the interval to pass
                    tvalid <= '0';
                    tlast  <= '0';

                    if counter = INTERVAL - 1 then
                        counter    <= 0;
                        sending    <= true;    -- Start sending
                        byte_index <= 0;       -- Ensure reset to 0 only here
                    else
                        counter <= counter + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;
end generate GEN_TEST_2;


end Behavioral;
