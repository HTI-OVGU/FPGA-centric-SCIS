library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity custom_fifo is
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
end custom_fifo;

-- architecture rtl of custom_fifo is

--   -- FIFO Storage
--   type t_DATA_ARRAY is array (0 to g_DEPTH-1) of std_logic_vector(g_WIDTH-1 downto 0);
--   type t_LAST_ARRAY is array (0 to g_DEPTH-1) of std_logic;

--   signal r_RD_ADDR : integer range 0 to g_DEPTH-1 := 0;

--   signal r_FIFO_DATA : t_DATA_ARRAY;
--   signal r_FIFO_LAST : t_LAST_ARRAY;

--   -- Pointers and Counter
--   signal r_WR_INDEX   : integer range 0 to g_DEPTH-1 := 0;
--   signal r_RD_INDEX   : integer range 0 to g_DEPTH-1 := 0;
--   signal r_FIFO_COUNT : integer range 0 to g_DEPTH   := 0;

--   -- Output Registers
--   signal r_out_data  : std_logic_vector(g_WIDTH-1 downto 0) := (others => '0');
--   signal r_out_last  : std_logic := '0';
--   signal r_valid     : std_logic := '0';  -- drives m_axis_tvalid

--   -- Internal Ready Signal
--   signal s_axis_tready_int : std_logic;

-- begin

--   -- AXIS Slave Interface: Accept data when not full
--   s_axis_tready_int <= '1' when r_FIFO_COUNT < g_DEPTH else '0';
--   s_axis_tready     <= s_axis_tready_int;

--   -- AXIS Master Interface
--   m_axis_tvalid <= r_valid;
--   m_axis_tdata  <= r_out_data;
--   m_axis_tlast  <= r_out_last;

--   -- Main control process
--   p_fifo : process(i_clk)
--     variable v_write_en : boolean;
--     variable v_read_en  : boolean;
--     variable next_rd_index : integer range 0 to g_DEPTH-1;
--   begin
--     if rising_edge(i_clk) then
--       if i_rst_sync = '1' then
--         -- Reset everything
--         r_WR_INDEX    <= 0;
--         r_RD_INDEX    <= 0;
--         r_FIFO_COUNT  <= 0;
--         r_out_data    <= (others => '0');
--         r_out_last    <= '0';
--         r_valid       <= '0';

--       else
--         -- Determine whether to write/read
--         v_write_en := (s_axis_tvalid = '1' and s_axis_tready_int = '1');
--         v_read_en  := (r_valid = '1' and m_axis_tready = '1');

--         -- FIFO count management
--         if v_write_en and not v_read_en then
--           r_FIFO_COUNT <= r_FIFO_COUNT + 1;
--         elsif not v_write_en and v_read_en then
--           r_FIFO_COUNT <= r_FIFO_COUNT - 1;
--         elsif v_write_en and v_read_en then
--           r_FIFO_COUNT <= r_FIFO_COUNT;  -- No change
--         end if;

--         -- Write logic
--         if v_write_en then
--           r_FIFO_DATA(r_WR_INDEX) <= s_axis_tdata;
--           r_FIFO_LAST(r_WR_INDEX) <= s_axis_tlast;
--           if r_WR_INDEX = g_DEPTH - 1 then
--             r_WR_INDEX <= 0;
--           else
--             r_WR_INDEX <= r_WR_INDEX + 1;
--           end if;
--         end if;

--         -- Preload output if not valid and FIFO not empty
--         if r_valid = '0' and r_FIFO_COUNT > 0 then
--           r_out_data <= r_FIFO_DATA(r_RD_INDEX);
--           r_out_last <= r_FIFO_LAST(r_RD_INDEX);
--           r_valid    <= '1';
--         end if;

--         -- Read logic: advance pointer after data consumed
--         if v_read_en then
--           if r_FIFO_COUNT > 1 then
--             -- FIFO will not be empty after read
--             if r_RD_INDEX = g_DEPTH - 1 then
--               next_rd_index := 0;
--             else
--               next_rd_index := r_RD_INDEX + 1;
--             end if;
--             r_RD_INDEX <= next_rd_index;
--             r_out_data <= r_FIFO_DATA(next_rd_index);
--             r_out_last <= r_FIFO_LAST(next_rd_index);
--           else
--             -- FIFO will be empty after read
--             r_valid <= '0';
--             if r_RD_INDEX = g_DEPTH - 1 then
--               r_RD_INDEX <= 0;
--             else
--               r_RD_INDEX <= r_RD_INDEX + 1;
--             end if;
--           end if;
--         end if;

--       end if;
--     end if;
--   end process;

-- end rtl;

architecture rtl of custom_fifo is
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
  signal delayed_fifo_count : unsigned(c_ADDR_WIDTH downto 0);
  signal delayed_fifo_empty : std_logic;
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
  --read_en  <= fetch_packet and (not fifo_empty);
  --read_en <= '1' when (fifo_empty = '0') and (prefetch_valid = '0') and (rd_pending = '0') else '0'; --combines what used to be fetch_packet  (with bubbles)
  -- read_en <= '1' when (fifo_empty = '0') and (rd_pending = '0') and
  --                 ( (prefetch_valid = '0') or
  --                   (prefetch_valid = '1' and current_candidate_valid = '1' and m_axis_tready = '1') )
  --          else '0';

  --my version:
  read_en <= '1' when fifo_empty = '0' and (((current_candidate_valid = '0') and (prefetch_valid = '0')) or ((current_candidate_has_been_read = '1'))) else '0';

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
      delayed_fifo_count <= fifo_count;
      delayed_fifo_empty <= fifo_empty;
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

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if(current_candidate_has_been_read = '1' and prev_current_candidate_has_been_read = '1') then
        burst_read_mode <= '1';
      end if;

      if(m_axis_tlast_reg = '1' and m_axis_tvalid_reg = '1' and m_axis_tready = '1') then
        burst_read_mode <= '0';
      end if;
      prev_current_candidate_has_been_read <= current_candidate_has_been_read;
    end if;
  end process;

  m_axis_tdata_reg <= current_candidate_data(g_WIDTH-3 downto 0) when burst_read_mode = '0' else prefetch_reg(g_WIDTH-3 downto 0);
  m_axis_tlast_reg <= current_candidate_data(g_WIDTH - 2) when burst_read_mode = '0' else prefetch_reg(g_WIDTH - 2);
  m_axis_tvalid_reg <= current_candidate_valid when burst_read_mode = '0' else prefetch_valid;

  -- fetch_packet <= ((not current_candidate_valid) or (current_candidate_has_been_read and not fifo_empty)) and (not rd_pending); --current packet has been read or new data just arrived in fifo

  -- Capture BRAM result and manage buffer state
  process(i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst_sync = '1' then
        current_candidate_data       <= (others => '0');
        current_candidate_valid     <= '0';
        prefetch_reg   <= (others => '0');
        prefetch_valid <= '0';
      else

        -- BRAM output arrives one cycle after read_en (rd_pending was set)
        if delayed_read_en = '1' then
          prefetch_reg   <= bram_dob;
          prefetch_valid <= '1';
        end if;

        -- On AXIS handshake: consume dout_reg
        if current_candidate_valid = '1' and m_axis_tready = '1' then
          if prefetch_valid = '1' and burst_read_mode = '0' then
            -- move prefetch to dout and keep valid high (no bubble)
            current_candidate_data       <= prefetch_reg;
            current_candidate_valid     <= '1';
            prefetch_valid <= '0';
          else
            -- no prefetched word available: clear dout_valid (becomes empty)
            current_candidate_valid <= '0';
          end if;
        end if;

        -- If we currently have no dout and a prefetched word exists, move it to dout
        if current_candidate_valid = '0' and prefetch_valid = '1' and burst_read_mode = '0' then
          current_candidate_data     <= prefetch_reg;
          current_candidate_valid   <= '1';

          if(delayed_read_en = '1') then
            prefetch_valid <= '1';
          else
            prefetch_valid <= '0';
          end if;
        end if;

        if(m_axis_tlast_reg = '1' and m_axis_tvalid_reg = '1' and m_axis_tready = '1' and fifo_count = 0) then -- if the last was received, we clear the whole "pipeline"
          current_candidate_valid <= '0';
          prefetch_valid <= '0';
        end if;
      end if;
    end if;
  end process;

  -- Connect output signals
  m_axis_tvalid <= m_axis_tvalid_reg;
  m_axis_tdata  <= m_axis_tdata_reg;
  m_axis_tlast  <= m_axis_tlast_reg;

end architecture rtl;
