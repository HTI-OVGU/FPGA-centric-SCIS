--------------------------------------------------------------------------------
-- tb_priority_fifo - isolate the FWFT priority FIFO read path.
--
-- Writes 9 DISTINCT bytes (0x10..0x18, tlast on the last) then reads them back
-- with m_axis_tready held high, and checks the read-out sequence + tlast. This
-- pins the telemetry-drain defect to the FIFO (prefetch/burst_read_mode) or
-- exonerates it. Distinct values make a "repeat head / reorder / drop" obvious.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_priority_fifo is
end entity tb_priority_fifo;

architecture sim of tb_priority_fifo is
  constant W          : natural := 10;
  constant CLK_PERIOD : time    := 25 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal s_tvalid : std_logic := '0';
  signal s_tlast  : std_logic := '0';
  signal s_tready : std_logic;
  signal s_tdata  : std_logic_vector(7 downto 0) := (others => '0');

  signal m_tvalid : std_logic;
  signal m_tlast  : std_logic;
  signal m_tdata  : std_logic_vector(7 downto 0);
  signal m_tready : std_logic := '0';
  signal af       : std_logic;

  type barr is array (0 to 8) of std_logic_vector(7 downto 0);
  constant PKT : barr :=
    (x"10", x"11", x"12", x"13", x"14", x"15", x"16", x"17", x"18");

  signal cap      : barr := (others => (others => '0'));
  signal cap_n    : integer := 0;
  signal last_pos : integer := -1;

  function hx(b : std_logic_vector(7 downto 0)) return string is
    constant d : string(1 to 16) := "0123456789ABCDEF";
    variable v : integer := to_integer(unsigned(b));
  begin
    return d(1 + v/16) & d(1 + (v mod 16));
  end function;

begin

  clk <= not clk after CLK_PERIOD / 2;

  dut : entity work.priority_axis_data_fifo
    generic map (g_WIDTH => W, g_DEPTH => 2047)
    port map (
      i_clk         => clk,
      i_rst_sync    => rst,
      s_axis_tvalid => s_tvalid,
      s_axis_tdata  => s_tdata,
      s_axis_tlast  => s_tlast,
      s_axis_tready => s_tready,
      m_axis_tvalid => m_tvalid,
      m_axis_tdata  => m_tdata,
      m_axis_tlast  => m_tlast,
      m_axis_tready => m_tready,
      almost_full   => af
    );

  capture : process (clk)
    variable idx : integer := 0;
  begin
    if rising_edge(clk) then
      if m_tvalid = '1' and m_tready = '1' then
        if idx <= 8 then cap(idx) <= m_tdata; end if;
        if m_tlast = '1' and last_pos < 0 then last_pos <= idx; end if;
        idx   := idx + 1;
        cap_n <= idx;
      end if;
    end if;
  end process capture;

  stim : process
    variable errors : integer := 0;
    procedure chk(c : boolean; m : string) is
    begin
      if not c then report m severity error; errors := errors + 1; end if;
    end procedure;
  begin
    rst <= '1';
    for i in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    -- write 9 bytes (FIFO empty => s_tready stays high)
    for i in 0 to 8 loop
      s_tvalid <= '1';
      s_tdata  <= PKT(i);
      if i = 8 then s_tlast <= '1'; else s_tlast <= '0'; end if;
      wait until rising_edge(clk);
    end loop;
    s_tvalid <= '0';
    s_tlast  <= '0';

    -- drain
    for i in 1 to 3 loop wait until rising_edge(clk); end loop;
    m_tready <= '1';
    wait for 5 us;
    m_tready <= '0';

    report "FIFO OUT[0..8] = "
         & hx(cap(0)) & " " & hx(cap(1)) & " " & hx(cap(2)) & " "
         & hx(cap(3)) & " " & hx(cap(4)) & " " & hx(cap(5)) & " "
         & hx(cap(6)) & " " & hx(cap(7)) & " " & hx(cap(8))
         & " | n=" & integer'image(cap_n)
         & " tlast@" & integer'image(last_pos);

    chk(cap_n = 9, "FIFO: expected exactly 9 beats out, got " & integer'image(cap_n));
    for i in 0 to 8 loop
      chk(cap(i) = PKT(i), "FIFO byte " & integer'image(i) & " mismatch (got "
          & hx(cap(i)) & " exp " & hx(PKT(i)) & ")");
    end loop;
    chk(last_pos = 8, "FIFO: tlast not on the 9th beat (got @" & integer'image(last_pos) & ")");

    if errors = 0 then
      report "PRIORITY FIFO TEST PASSED" severity note;
    else
      report "PRIORITY FIFO TEST FAILED: " & integer'image(errors) & " error(s)" severity failure;
    end if;
    finish;
    wait;
  end process stim;

end architecture sim;
