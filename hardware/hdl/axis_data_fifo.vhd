library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axis_data_fifo is -- axi stream data fifo for the W5500 controller and SPI Master (8 bit data + last bit)
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
end axis_data_fifo;

architecture rtl of axis_data_fifo is
  -- Address width derived from the depth actually asked for, not a literal.
  --
  -- It used to be the constant 10 while every instance asks for g_DEPTH = 2047,
  -- so the pointers addressed 1024 entries. fifo_full is only raised at
  -- fifo_count = g_DEPTH, so the FIFO went on accepting writes long after its
  -- memory had wrapped and entry 1024 landed on top of entry 0, unread. The
  -- receive path reads a whole 2 KB socket buffer in one SPI transaction --
  -- 2040 bytes, every one of them through here -- so any backlog past 1024
  -- destroyed the ones underneath it. tb_axis_fifo_depth pins it down: 1024
  -- words come back intact, 2040 words come back with 1014 corrupted.
  --
  -- metric_packet_fifo and priority_fifo carry the same defect and the same fix.
  function clog2(n : natural) return natural is
    variable r : natural := 0;
    variable v : natural := n - 1;
  begin
    while v > 0 loop
      r := r + 1;
      v := v / 2;
    end loop;
    return r;
  end function;

  constant c_ADDR_WIDTH : natural := clog2(g_DEPTH + 1);
  
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

  -- Pipelined control signals
  signal need_data : std_logic;
  signal can_provide : std_logic;
  signal fifo_empty_reg : std_logic;
  signal fifo_full_reg : std_logic;

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

  -- Burst read path disabled.
  --
  -- It latched after two back-to-back reads and from then on drove the output
  -- from prefetch_reg with m_axis_tvalid <= prefetch_valid -- but every
  -- assignment that clears prefetch_valid is guarded by burst_read_mode = '0',
  -- so in burst mode nothing ever retired the word. An empty FIFO went on
  -- asserting tvalid with the last word it had fetched, and a ready consumer
  -- took that same word again on every clock.
  --
  -- In the W5500 transmit path that turned any gap in the fabric into duplicate
  -- bytes inside an already-open SPI transaction: the chip wrote them into its
  -- transmit buffer at auto-incremented addresses while Sn_TX_WR was advanced
  -- only by the number of bytes the fabric had actually handed over, so the
  -- datagram came out carrying a repeated byte with everything behind it
  -- displaced. tb_axis_fifo_starve pins the defect down on this module alone.
  --
  -- What is left is an ordinary skid buffer, and it is correct when empty. It
  -- sustains two words every three clocks -- more than ten times what the SPI
  -- master can take (one byte per sixteen clocks) -- so nothing that reads this
  -- FIFO is slowed down by the change.
  burst_read_mode <= '0';

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
            -- A word from BRAM may be landing in prefetch_reg this very cycle
            -- (the block above). Clearing prefetch_valid unconditionally would
            -- overwrite that '1' -- last assignment wins -- and the word would
            -- be dropped, silently shortening the stream. The mirror branch
            -- below already makes this distinction; this one did not, and the
            -- burst path used to hide it by never taking this branch at all.
            if delayed_read_en = '1' then
              prefetch_valid <= '1';
            else
              prefetch_valid <= '0';
            end if;
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

        -- End-of-packet flush. It may only fire when the pipeline is genuinely
        -- empty behind the last beat: read_en never fetches a word that was not
        -- written, so anything sitting in prefetch_reg -- or landing in it this
        -- cycle -- is the first byte of the NEXT packet, and clearing the flags
        -- would drop it. Back-to-back packets in the W5500 transmit path hit
        -- exactly that: the leading 'V' of a record goes missing and every byte
        -- behind it shifts by one. The two blocks above already retire beats
        -- correctly, so this one only has to cover the idle case.
        if(m_axis_tlast_reg = '1' and m_axis_tvalid_reg = '1' and m_axis_tready = '1'
           and fifo_count = 0 and prefetch_valid = '0' and delayed_read_en = '0') then
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
