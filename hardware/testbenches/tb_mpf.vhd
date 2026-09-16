--------------------------------------------------------------------------------
-- tb_mpf - metric_packet_fifo read side under TOGGLING m_axis_tready.
--
-- priority_fifo (same FWFT prefetch/burst design) passed with tready held high.
-- But in the DC, the metric_packet_manager back-pressures threshold_logic's
-- buffer_fifo with a toggling tready. This bench writes 9 distinct bytes then
-- drains them with tready pulsed (1 cycle ready, 2 cycles not) to expose any
-- prefetch/burst bug that only shows under backpressure.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_mpf is
end entity tb_mpf;

architecture sim of tb_mpf is
  constant CLK_PERIOD : time := 25 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal s_tvalid : std_logic := '0';
  signal s_tlast  : std_logic := '0';
  signal s_tready : std_logic;
  signal s_tdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal s_tuser  : std_logic_vector(2 downto 0) := (others => '0');

  signal m_tvalid : std_logic;
  signal m_tlast  : std_logic;
  signal m_tdata  : std_logic_vector(7 downto 0);
  signal m_tuser  : std_logic_vector(2 downto 0);
  signal m_tready : std_logic := '0';

  type barr is array (0 to 8) of std_logic_vector(7 downto 0);
  constant PKT : barr :=
    (x"10", x"11", x"12", x"13", x"14", x"15", x"16", x"17", x"18");

  signal cap      : barr := (others => (others => '0'));
  signal cap_n    : integer := 0;
  signal last_pos : integer := -1;
  signal bad_user : integer := 0;

  function hx(b : std_logic_vector(7 downto 0)) return string is
    constant d : string(1 to 16) := "0123456789ABCDEF";
    variable v : integer := to_integer(unsigned(b));
  begin
    return d(1 + v/16) & d(1 + (v mod 16));
  end function;

begin

  clk <= not clk after CLK_PERIOD / 2;

  dut : entity work.metric_packet_fifo(rtl)
    generic map (g_WIDTH => 20, g_DEPTH => 1023)
    port map (
      i_clk         => clk,
      i_rst_sync    => rst,
      s_axis_tvalid => s_tvalid,
      s_axis_tdata  => s_tdata,
      s_axis_tlast  => s_tlast,
      s_axis_tready => s_tready,
      s_axis_tuser  => s_tuser,
      m_axis_tvalid => m_tvalid,
      m_axis_tdata  => m_tdata,
      m_axis_tlast  => m_tlast,
      m_axis_tready => m_tready,
      m_axis_tuser  => m_tuser
    );

  capture : process (clk)
    variable idx : integer := 0;
  begin
    if rising_edge(clk) then
      if m_tvalid = '1' and m_tready = '1' then
        if idx <= 8 then cap(idx) <= m_tdata; end if;
        if m_tuser /= "010" then bad_user <= bad_user + 1; end if;
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

    for i in 0 to 8 loop
      s_tvalid <= '1';
      s_tdata  <= PKT(i);
      s_tuser  <= "010";
      if i = 8 then s_tlast <= '1'; else s_tlast <= '0'; end if;
      wait until rising_edge(clk);
    end loop;
    s_tvalid <= '0';
    s_tlast  <= '0';

    for i in 1 to 3 loop wait until rising_edge(clk); end loop;

    -- DRAIN with toggling ready: 1 cycle ready, 2 cycles not (backpressure)
    for k in 0 to 60 loop
      m_tready <= '1';
      wait until rising_edge(clk);
      m_tready <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
    end loop;

    report "MPF OUT[0..8] = "
         & hx(cap(0)) & " " & hx(cap(1)) & " " & hx(cap(2)) & " "
         & hx(cap(3)) & " " & hx(cap(4)) & " " & hx(cap(5)) & " "
         & hx(cap(6)) & " " & hx(cap(7)) & " " & hx(cap(8))
         & " | n=" & integer'image(cap_n)
         & " tlast@" & integer'image(last_pos)
         & " bad_user=" & integer'image(bad_user);

    chk(cap_n = 9, "MPF: expected exactly 9 beats out, got " & integer'image(cap_n));
    for i in 0 to 8 loop
      chk(cap(i) = PKT(i), "MPF byte " & integer'image(i) & " mismatch (got "
          & hx(cap(i)) & " exp " & hx(PKT(i)) & ")");
    end loop;
    chk(last_pos = 8, "MPF: tlast not on the 9th beat (got @" & integer'image(last_pos) & ")");
    chk(bad_user = 0, "MPF: tuser corrupted on " & integer'image(bad_user) & " beat(s)");

    if errors = 0 then
      report "METRIC PACKET FIFO (toggling ready) TEST PASSED" severity note;
    else
      report "METRIC PACKET FIFO TEST FAILED: " & integer'image(errors) & " error(s)" severity failure;
    end if;
    finish;
    wait;
  end process stim;

end architecture sim;
