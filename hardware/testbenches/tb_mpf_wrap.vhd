-- Does metric_packet_fifo survive more entries than its pointers can address?
-- g_DEPTH = 1023 but c_ADDR_WIDTH = 9, so write_ptr/read_ptr are 9-bit (0..511)
-- and `write_ptr = g_DEPTH - 1` (1022) can never be true. Fill past 512 with no
-- reads, then drain and compare. Values are mod 251 (prime) so an aliased entry
-- cannot coincidentally match the expected one.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mpf_wrap is
end entity;

architecture sim of tb_mpf_wrap is
  constant N_WRITE : integer := 600;
  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal s_tvalid : std_logic := '0';
  signal s_tdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal s_tlast  : std_logic := '0';
  signal s_tready : std_logic;
  signal s_tuser  : std_logic_vector(2 downto 0) := "000";
  signal m_tvalid : std_logic;
  signal m_tdata  : std_logic_vector(7 downto 0);
  signal m_tlast  : std_logic;
  signal m_tready : std_logic := '0';
  signal m_tuser  : std_logic_vector(2 downto 0);
begin
  clk <= not clk after 5 ns;

  dut : entity work.metric_packet_fifo
    generic map (g_WIDTH => 20, g_DEPTH => 1023)
    port map (
      i_clk => clk, i_rst_sync => rst,
      s_axis_tvalid => s_tvalid, s_axis_tdata => s_tdata,
      s_axis_tlast => s_tlast, s_axis_tready => s_tready, s_axis_tuser => s_tuser,
      m_axis_tvalid => m_tvalid, m_axis_tdata => m_tdata,
      m_axis_tlast => m_tlast, m_axis_tready => m_tready, m_axis_tuser => m_tuser);

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

    -- Fill, never reading.
    m_tready <= '0';
    s_tvalid <= '1';
    while wrote < N_WRITE and guard < 100000 loop
      s_tdata <= std_logic_vector(to_unsigned(wrote mod 251, 8));
      wait until rising_edge(clk);
      if s_tready = '1' then
        wrote := wrote + 1;
      end if;
      guard := guard + 1;
    end loop;
    s_tvalid <= '0';
    report "accepted " & integer'image(wrote) & " writes (asked for "
           & integer'image(N_WRITE) & ")";

    -- Drain and compare against what was written, in order.
    wait until rising_edge(clk);
    m_tready <= '1';
    guard := 0;
    while readb < wrote and guard < 200000 loop
      wait until rising_edge(clk);
      if m_tvalid = '1' then
        got  := to_integer(unsigned(m_tdata));
        want := readb mod 251;
        if got /= want then
          errors := errors + 1;
          if errors <= 4 then
            report "MISMATCH at entry " & integer'image(readb)
                   & ": expected " & integer'image(want)
                   & " got " & integer'image(got)
                   & "  (value written at index "
                   & integer'image(readb + 512) & ")" severity note;
          end if;
        end if;
        readb := readb + 1;
      end if;
      guard := guard + 1;
    end loop;

    report "read back " & integer'image(readb) & " entries, "
           & integer'image(errors) & " corrupted";
    if errors = 0 then
      report "FIFO WRAP TEST PASSED" severity note;
    else
      report "FIFO WRAP TEST FAILED: " & integer'image(errors)
             & " of " & integer'image(readb) & " entries corrupted" severity note;
    end if;
    std.env.stop;
  end process;
end architecture;
