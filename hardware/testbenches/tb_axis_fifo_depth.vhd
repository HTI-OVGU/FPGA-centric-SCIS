-- Does axis_data_fifo actually hold the depth it advertises?
--
-- The entity takes g_DEPTH and every instance asks for 2047, but c_ADDR_WIDTH
-- is the literal 10, so the pointers address 1024 entries. fifo_full is only
-- asserted at fifo_count = g_DEPTH, so the FIFO keeps accepting writes long
-- after its memory has wrapped, and entries 1024 upwards land on top of
-- unread ones.
--
-- It matters because the receive path reads a whole socket buffer in one SPI
-- transaction: 2 KB is 2040 bytes, and every one of them passes through this
-- FIFO. Whenever the fabric downstream cannot keep up, the backlog grows past
-- 1024 and the oldest entries are overwritten before anyone reads them.
--
-- The same defect was already found and fixed in metric_packet_fifo and
-- priority_fifo, where c_ADDR_WIDTH is now derived from g_DEPTH.
--
-- Fill without reading, then drain and compare. Values are mod 251, a prime, so
-- an aliased entry cannot coincidentally match the expected one.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_axis_fifo_depth is
  generic (
    G_DEPTH : natural := 2047;
    G_WRITE : integer := 1500     -- past 1024, inside the advertised depth
  );
end entity;

architecture sim of tb_axis_fifo_depth is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal s_tvalid : std_logic := '0';
  signal s_tdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal s_tlast  : std_logic := '0';
  signal s_tready : std_logic;
  signal m_tvalid : std_logic;
  signal m_tdata  : std_logic_vector(7 downto 0);
  signal m_tlast  : std_logic;
  signal m_tready : std_logic := '0';
begin
  clk <= not clk after 5 ns;

  dut : entity work.axis_data_fifo
    generic map (g_WIDTH => 10, g_DEPTH => G_DEPTH)
    port map (
      i_clk => clk, i_rst_sync => rst,
      s_axis_tvalid => s_tvalid, s_axis_tdata => s_tdata,
      s_axis_tlast => s_tlast, s_axis_tready => s_tready,
      m_axis_tvalid => m_tvalid, m_axis_tdata => m_tdata,
      m_axis_tlast => m_tlast, m_axis_tready => m_tready);

  stim : process
    variable wrote  : integer := 0;
    variable readb  : integer := 0;
    variable errors : integer := 0;
    variable guard  : integer := 0;
    variable got    : integer;
    variable want   : integer;
  begin
    rst <= '1';
    wait for 100 ns;
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    -- fill, no reads at all
    while wrote < G_WRITE loop
      s_tdata  <= std_logic_vector(to_unsigned(wrote mod 251, 8));
      s_tlast  <= '0';
      s_tvalid <= '1';
      wait until rising_edge(clk);
      if s_tready = '1' then
        wrote := wrote + 1;
      end if;
      guard := guard + 1;
      exit when guard > 100000;
    end loop;
    s_tvalid <= '0';
    wait until rising_edge(clk);

    -- drain and compare
    m_tready <= '1';
    guard := 0;
    while readb < wrote loop
      wait until rising_edge(clk);
      if m_tvalid = '1' then
        got  := to_integer(unsigned(m_tdata));
        want := readb mod 251;
        if got /= want then
          if errors < 5 then
            report "entry " & integer'image(readb) & ": expected "
                 & integer'image(want) & ", got " & integer'image(got)
              severity warning;
          end if;
          errors := errors + 1;
        end if;
        readb := readb + 1;
      end if;
      guard := guard + 1;
      exit when guard > 200000;
    end loop;

    report "=== tb_axis_fifo_depth (g_DEPTH = " & integer'image(G_DEPTH) & ") ==="
      severity note;
    report "accepted " & integer'image(wrote) & " writes, read back "
         & integer'image(readb) & ", " & integer'image(errors) & " corrupted"
      severity note;

    assert wrote = G_WRITE
      report "FIFO refused writes at " & integer'image(wrote)
           & " while advertising depth " & integer'image(G_DEPTH) severity error;
    assert errors = 0
      report "ALIASED ENTRIES: " & integer'image(errors) severity error;

    if wrote = G_WRITE and errors = 0 and readb = wrote then
      report "PASS" severity note;
    else
      report "FAIL" severity note;
    end if;
    finish;
  end process;
end architecture;
