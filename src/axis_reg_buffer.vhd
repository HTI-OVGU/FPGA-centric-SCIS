library ieee;
use ieee.std_logic_1164.all;

entity axis_reg_buffer is
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;
        
        -- AXI Stream Input
        s_tdata      : in  std_logic_vector(7 downto 0);
        s_tlast      : in  std_logic;
        s_tuser      : in  std_logic_vector(2 downto 0);
        s_tvalid     : in  std_logic;
        s_tready     : out std_logic;
        
        -- AXI Stream Output
        m_tdata      : out std_logic_vector(7 downto 0);
        m_tlast      : out std_logic;
        m_tuser      : out std_logic_vector(2 downto 0);
        m_tvalid     : out std_logic;
        m_tready     : in  std_logic
    );
end axis_reg_buffer;

architecture rtl of axis_reg_buffer is
    
    -- Output register
    signal reg_tdata   : std_logic_vector(7 downto 0);
    signal reg_tuser   : std_logic_vector(2 downto 0);
    signal reg_tvalid  : std_logic;
    signal reg_tlast   : std_logic;
    
    signal s_tready_int : std_logic;
    
begin
    
    -- Output assignments
    m_tdata  <= reg_tdata;
    m_tlast  <= reg_tlast;
    m_tuser  <= reg_tuser;
    m_tvalid <= reg_tvalid;
    s_tready <= s_tready_int;
    
    -- Combined register slice + latch process
    process(clk, reset)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                reg_tvalid <= '0';
                reg_tdata  <= (others => '0');
                reg_tuser  <= (others => '0');
                reg_tlast  <= '0';
            else
                -- Default: keep reg_tvalid unless consumed or replaced below
                -- Case A: We currently hold a valid beat in register
                if reg_tvalid = '1' then
                    -- If downstream accepted this beat, clear reg_tvalid
                    if m_tready = '1' then
                        reg_tvalid <= '0';
                        -- Optionally: if upstream also has a beat available in the
                        -- same cycle (and upstream tready was true), capture it
                        if (s_tvalid = '1' and
                            s_tready_int = '1') then
                            -- capture new beat immediately (pipeline)
                            reg_tdata  <= s_tdata;
                            reg_tuser  <= s_tuser;
                            reg_tlast  <= s_tlast;
                            reg_tvalid <= '1';
                        end if;
                    end if;

                -- Case B: register empty, accept an upstream beat if it's available
                else  -- reg_tvalid = '0'
                    if (s_tvalid = '1' and
                        s_tready_int = '1') then
                        -- Accept the beat into the register
                        reg_tdata  <= s_tdata;
                        reg_tuser  <= s_tuser;
                        reg_tlast  <= s_tlast;
                        reg_tvalid <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    s_tready_int <= (not reg_tvalid) or m_tready;
end rtl;