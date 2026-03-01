library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_data_fifo is -- axi stream data fifo for the W5500 controller and SPI Master (8 bit data + last bit)
  generic (
    g_WIDTH : natural := 10;
    g_DEPTH : natural := 2047
  );
  port (
    i_clk          : in  std_logic;
    i_rst_sync     : in  std_logic; -- Active-High Synchronous Reset

    -- AXI Stream Slave Interface (Write Side)
    s_axis_tvalid  : in  std_logic;
    s_axis_tdata   : in  std_logic_vector(g_WIDTH-3 downto 0);
    s_axis_tlast   : in  std_logic;
    s_axis_tready  : out std_logic;

    -- AXI Stream Master Interface (Read Side)
    m_axis_tvalid  : out std_logic;
    m_axis_tdata   : out std_logic_vector(g_WIDTH-3 downto 0);
    m_axis_tlast   : out std_logic;
    m_axis_tready  : in  std_logic
  );
end axi_data_fifo;

architecture rtl of axi_data_fifo is
  -- Calculate address width based on FIFO depth
  constant c_ADDR_WIDTH : natural := natural(10);
  
  -- Internal signals for BRAM interface
  signal bram_wea    : std_logic;
  signal bram_web    : std_logic;
  signal bram_dia    : std_logic_vector(g_WIDTH - 1  downto 0); -- +1 for TLAST
  signal bram_dib    : std_logic_vector(g_WIDTH - 1 downto 0);
  signal bram_addra  : std_logic_vector(c_ADDR_WIDTH-1 downto 0);
  signal bram_addrb  : std_logic_vector(c_ADDR_WIDTH-1 downto 0);
  signal bram_doa    : std_logic_vector(g_WIDTH - 1 downto 0);
  signal bram_dob    : std_logic_vector(g_WIDTH - 1 downto 0);
  
  -- FIFO control signals
  signal write_ptr   : unsigned(c_ADDR_WIDTH-1 downto 0);
  signal read_ptr    : unsigned(c_ADDR_WIDTH-1 downto 0);
  signal fifo_count  : unsigned(c_ADDR_WIDTH downto 0); -- +1 bit for full detection
  

  signal fifo_full   : std_logic;
  signal fifo_empty  : std_logic;
  signal write_en    : std_logic;
  signal read_en     : std_logic;

  signal delayed_read_en : std_logic;

  -- Output register signals
  signal m_axis_tvalid_reg : std_logic;
  signal m_axis_tdata_reg  : std_logic_vector(g_WIDTH-3 downto 0);
  signal m_axis_tlast_reg  : std_logic;

  signal rw_concat_enable :STD_LOGIC_VECTOR(1 downto 0);

  signal current_candidate_valid : std_logic;
  signal current_candidate_data : std_logic_vector(g_WIDTH-1 downto 0);
  signal current_candidate_has_been_read : std_logic;
  signal prev_current_candidate_has_been_read : std_logic;

  signal prefetch_reg     : std_logic_vector(g_WIDTH-1 downto 0) := (others => '0');
  signal prefetch_valid   : std_logic := '0';

  signal fetch_packet : std_logic;
  signal rd_pending : std_logic := '0';
  
  signal burst_read_mode : std_logic := '0';

  component bram_dp_write_through is
    generic (
    DATA_WIDTH : integer := g_WIDTH;
    ADDR_WIDTH : integer := 11
    );
    port (
    wea : in std_logic;
    web : in std_logic;
    clka : in std_logic;
    clkb : in std_logic;
    dia : in std_logic_vector(DATA_WIDTH-1 downto 0);
    dib : in std_logic_vector(DATA_WIDTH-1 downto 0);
    addra : in std_logic_vector(ADDR_WIDTH-1 downto 0);
    addrb : in std_logic_vector(ADDR_WIDTH-1 downto 0);
    doa : out std_logic_vector(DATA_WIDTH-1 downto 0);
    dob : out std_logic_vector(DATA_WIDTH-1 downto 0)
    );
    end component;

begin
  
  -- FIFO status flags
  fifo_full  <= '1' when fifo_count = g_DEPTH else '0';
  fifo_empty <= '1' when fifo_count = 0 else '0';
  
  -- Write and read enable logic
  write_en <= s_axis_tvalid and (not fifo_full);
  read_en <= '1' when (fifo_empty = '0' and delayed_read_en = '0') and (current_candidate_valid = '0' or current_candidate_has_been_read = '1') else '0';

  -- AXI Stream ready signals
  s_axis_tready <= not fifo_full;
  
  -- BRAM control signals
  bram_wea   <= write_en;
  bram_web   <= '0'; -- Port B is read-only
  bram_addra <= std_logic_vector(write_ptr);
  bram_addrb <= std_logic_vector(read_ptr);
  bram_dia   <= '0' & s_axis_tlast & s_axis_tdata; -- Concatenate TLAST with data
  bram_dib   <= (others => '0'); -- Not used for read port
  
  -- Instantiate dual port BRAM
  u_bram :  bram_dp_write_through
    generic map (
      DATA_WIDTH => g_WIDTH, 
      ADDR_WIDTH => c_ADDR_WIDTH -- 11 for 2^11 = 2048
    )
    port map (
      wea    => bram_wea,
      web    => bram_web,
      clka   => i_clk,
      clkb   => i_clk,
      dia    => bram_dia,
      dib    => bram_dib,
      addra  => bram_addra,
      addrb  => bram_addrb,
      doa    => bram_doa,
      dob    => bram_dob
    );
  
  -- Write pointer management
  p_write_ptr : process(i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst_sync = '1' then
        write_ptr <= (others => '0');
      elsif write_en = '1' then
        if write_ptr = g_DEPTH - 1 then
          write_ptr <= (others => '0');
        else
          write_ptr <= write_ptr + 1;
        end if;
      end if;
    end if;
  end process p_write_ptr;
  
  -- delay read_en such that data is actually accessible from BRAM Port B when writing into prefetch registers

  process(i_clk)
  begin
    if rising_edge(i_clk) then
      delayed_read_en <= read_en;
    end if;
  end process;

  -- Read pointer management
  p_read_ptr : process(i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst_sync = '1' then
        read_ptr <= (others => '0');
      elsif read_en = '1' then
        if read_ptr = g_DEPTH - 1 then
          read_ptr <= (others => '0');
        else
          read_ptr <= read_ptr + 1;
        end if;
      end if;
    end if;
  end process p_read_ptr;
  
  rw_concat_enable <= write_en & read_en;

  -- FIFO count management
  p_fifo_count : process(i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst_sync = '1' then
        fifo_count <= (others => '0');
      else
        case (rw_concat_enable) is
          when "10" => -- Write only
            fifo_count <= fifo_count + 1;
          when "01" => -- Read only
            fifo_count <= fifo_count - 1;
          when others => -- Both or neither
            fifo_count <= fifo_count;
        end case;
      end if;
    end if;
  end process p_fifo_count;

  current_candidate_has_been_read <= m_axis_tvalid_reg and m_axis_tready; -- axis handshake

  m_axis_tdata_reg <= current_candidate_data(g_WIDTH-3 downto 0);
  m_axis_tlast_reg <= current_candidate_data(g_WIDTH - 2);
  m_axis_tvalid_reg <= current_candidate_valid;

  -- Capture BRAM result and manage buffer state
  process(i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst_sync = '1' then
        current_candidate_data  <= (others => '0');
        current_candidate_valid <= '0';
      else
        -- Handle handshake consuming current data
        if (m_axis_tvalid_reg = '1' and m_axis_tready = '1') then
          current_candidate_valid <= '0';
        end if;

        -- New data arriving from BRAM (this takes priority)
        if delayed_read_en = '1' then
          current_candidate_data  <= bram_dob;
          current_candidate_valid <= '1';  -- Overrides the clear above
        end if;
      end if;
    end if;
  end process;

  -- Connect output signals
  m_axis_tvalid <= m_axis_tvalid_reg;
  m_axis_tdata  <= m_axis_tdata_reg;
  m_axis_tlast  <= m_axis_tlast_reg;

end architecture rtl;
