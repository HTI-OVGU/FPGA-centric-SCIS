library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;
use work.metric_axi_stream_pkg.all;

entity udp_packet_adapter is
    port (
        clk         : in  STD_LOGIC;
        reset       : in  STD_LOGIC;

        rdata       : in  STD_LOGIC_VECTOR(7 downto 0);
        rlast       : in  STD_LOGIC;
        rvalid      : in  STD_LOGIC := '0';
        rready      : out STD_LOGIC := '0';
        ruser       : in  STD_LOGIC_VECTOR(2 downto 0);

        tdata       : out  STD_LOGIC_VECTOR(7 downto 0);
        tlast       : out  STD_LOGIC;
        tvalid      : out  STD_LOGIC;
        tready      : in STD_LOGIC;
        tuser       : out  STD_LOGIC_VECTOR(2 downto 0)
    );
end udp_packet_adapter;

architecture Behavioral of udp_packet_adapter is

    type state_type is (IDLE, READ_HEADER, FORWARD_PAYLOAD, DISCARD);
    signal state : state_type := IDLE;
    
    signal byte_counter : integer := 0;
    signal length_field : std_logic_vector(15 downto 0) := (others => '0');
    signal first_payload_byte : std_logic_vector(7 downto 0) := (others => '0');
    signal valid_packet : std_logic := '0';

    -- FIFO signals
    signal s_axis : metric_axi_stream_t;
    signal s_axis_tready : std_logic;
    signal m_axis : metric_axi_stream_t;

    component metric_packet_fifo is
        generic (
            g_WIDTH : natural := 20;
            g_DEPTH : natural := 1023
        );
        port (
            i_clk          : in  std_logic;
            i_rst_sync     : in  std_logic;
            s_axis_tvalid  : in  std_logic;
            s_axis_tdata   : in  std_logic_vector(7 downto 0);
            s_axis_tlast   : in  std_logic;
            s_axis_tready  : out std_logic;
            s_axis_tuser   : in  std_logic_vector(2 downto 0);
            m_axis_tvalid  : out std_logic;
            m_axis_tdata   : out std_logic_vector(7 downto 0);
            m_axis_tlast   : out std_logic;
            m_axis_tready  : in  std_logic;
            m_axis_tuser   : out STD_LOGIC_VECTOR(2 downto 0)
        ); 
    end component;

begin

    -- Connect FIFO output to module output
    tdata <= m_axis.tdata;
    tvalid <= m_axis.tvalid;
    tlast <= m_axis.tlast;
    tuser <= m_axis.tuser;

    packet_buffer_fifo : metric_packet_fifo
    generic map(
        g_WIDTH => 20,
        g_DEPTH => 1023
    )
    port map(
        i_clk => clk,
        i_rst_sync => reset,
        s_axis_tvalid => s_axis.tvalid,
        s_axis_tdata => s_axis.tdata,
        s_axis_tlast => s_axis.tlast,
        s_axis_tready => s_axis_tready,
        s_axis_tuser => s_axis.tuser,
        m_axis_tvalid => m_axis.tvalid,
        m_axis_tdata => m_axis.tdata,
        m_axis_tlast => m_axis.tlast,
        m_axis_tready => tready,
        m_axis_tuser => m_axis.tuser
    );

    -- Main state machine
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                byte_counter <= 0;
                length_field <= (others => '0');
                first_payload_byte <= (others => '0');
                valid_packet <= '0';
                rready <= '0';
                s_axis.tvalid <= '0';
                s_axis.tdata <= (others => '0');
                s_axis.tlast <= '0';
                s_axis.tuser <= (others => '0');
            else
                -- Default: don't write to FIFO
                s_axis.tvalid <= '0';
                
                case state is
                    when IDLE =>
                        byte_counter <= 0;
                        valid_packet <= '0';
                        rready <= '0';
                        if rvalid = '1' then
                            state <= READ_HEADER;
                            rready <= '1';
                        end if;

                        s_axis.tdata <= x"00";
                        s_axis.tvalid <= '0';
                        s_axis.tlast <= '0';
                        s_axis.tuser <= "000";

                    when READ_HEADER =>
                        rready <= '1';
                        
                        s_axis.tdata <= x"00";
                        s_axis.tvalid <= '0';
                        s_axis.tlast <= '0';
                        s_axis.tuser <= "000";

                        if rvalid = '1' then
                            -- Capture length field (bytes 6-7)
                            if byte_counter = 6 then
                                length_field(15 downto 8) <= rdata;
                            elsif byte_counter = 7 then
                                length_field(7 downto 0) <= rdata;
                                -- Check if length is 9 and move to next state
                                if length_field(15 downto 8) & rdata = x"0009" then
                                    state <= FORWARD_PAYLOAD;
                                else
                                    state <= DISCARD;
                                end if;
                            end if;
                            
                            byte_counter <= byte_counter + 1;
                        end if;

                    when FORWARD_PAYLOAD =>
                        rready <= s_axis_tready;  -- Backpressure from FIFO
                        
                        if rvalid = '1' and s_axis_tready = '1' then
                            -- First payload byte: check for 'V' and write it
                            if byte_counter = 8 then
                                if rdata = x"56" then
                                    valid_packet <= '1';
                                    -- Write the 'V' to FIFO
                                    s_axis.tdata <= rdata;
                                    s_axis.tvalid <= '1';
                                    s_axis.tlast <= rlast;
                                    s_axis.tuser <= ruser;
                                else
                                    state <= DISCARD;
                                end if;
                            -- Write subsequent bytes if packet is valid
                            elsif byte_counter > 8 and valid_packet = '1' then
                                s_axis.tdata <= rdata;
                                s_axis.tvalid <= '1';
                                s_axis.tlast <= rlast;
                                s_axis.tuser <= ruser;
                            end if;
                            
                            byte_counter <= byte_counter + 1;
                            
                            if rlast = '1' and rvalid = '1' then
                                state <= IDLE;
                                rready <= '1';
                            end if;
                        end if;

                    when DISCARD =>
                        rready <= '1';
                        if rvalid = '1' and rlast = '1' then
                            state <= IDLE;
                        end if;

                        s_axis.tdata <= x"00";
                        s_axis.tvalid <= '0';
                        s_axis.tlast <= '0';
                        s_axis.tuser <= "000";

                end case;
            end if;
        end if;
    end process;

end Behavioral;