--------------------------------------------------------------------------------
-- tb_mpm - isolate metric_packet_manager (skid buffer + demux + arbiter).
--
-- Drives 9 DISTINCT bytes (0x10..0x18, tuser=000, tlast on the last) into input
-- stream 0 of a 2-stream manager (stream 1 idle), m_axis_tready high, and checks
-- the m_axis output sequence + tlast. Pins the drain defect to the manager (or
-- exonerates it, leaving threshold_logic). FIFO already proven good in isolation.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;
use work.metric_axi_stream_pkg.all;

entity tb_mpm is
end entity tb_mpm;

architecture sim of tb_mpm is
  constant CLK_PERIOD : time := 25 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal s_axis     : metric_axi_stream_array_t(0 to 1);
  signal s_tready   : std_logic_vector(1 downto 0);
  signal m_axis     : metric_axi_stream_t;
  signal m_tready   : std_logic := '1';
  signal af         : std_logic_vector(7 downto 0);

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

  dut : entity work.metric_packet_manager(Behavioral)
    generic map (metric_input_stream_amount => 2)
    port map (
      clk                => clk,
      reset              => rst,
      s_axis             => s_axis,
      s_axis_tready      => s_tready,
      m_axis             => m_axis,
      m_axis_tready      => m_tready,
      almost_full_vector => af
    );

  -- stream 1 idle
  s_axis(1) <= (tdata => (others => '0'), tuser => (others => '0'),
               tvalid => '0', tlast => '0');

  capture : process (clk)
    variable idx : integer := 0;
  begin
    if rising_edge(clk) then
      if m_axis.tvalid = '1' and m_tready = '1' then
        if idx <= 8 then cap(idx) <= m_axis.tdata; end if;
        if m_axis.tlast = '1' and last_pos < 0 then last_pos <= idx; end if;
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
    s_axis(0) <= (tdata => (others => '0'), tuser => (others => '0'),
                 tvalid => '0', tlast => '0');
    rst <= '1';
    for i in 1 to 6 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    -- drive the 9-byte packet on stream 0, tuser=000, honouring s_tready(0)
    for i in 0 to 8 loop
      s_axis(0).tdata  <= PKT(i);
      s_axis(0).tuser  <= "000";
      if i = 8 then s_axis(0).tlast <= '1'; else s_axis(0).tlast <= '0'; end if;
      s_axis(0).tvalid <= '1';
      loop
        wait until rising_edge(clk);
        exit when s_tready(0) = '1';
      end loop;
    end loop;
    s_axis(0).tvalid <= '0';
    s_axis(0).tlast  <= '0';

    wait for 8 us;

    report "MPM OUT[0..8] = "
         & hx(cap(0)) & " " & hx(cap(1)) & " " & hx(cap(2)) & " "
         & hx(cap(3)) & " " & hx(cap(4)) & " " & hx(cap(5)) & " "
         & hx(cap(6)) & " " & hx(cap(7)) & " " & hx(cap(8))
         & " | n=" & integer'image(cap_n)
         & " tlast@" & integer'image(last_pos);

    chk(cap_n = 9, "MPM: expected exactly 9 beats out, got " & integer'image(cap_n));
    for i in 0 to 8 loop
      chk(cap(i) = PKT(i), "MPM byte " & integer'image(i) & " mismatch (got "
          & hx(cap(i)) & " exp " & hx(PKT(i)) & ")");
    end loop;
    chk(last_pos = 8, "MPM: tlast not on the 9th beat (got @" & integer'image(last_pos) & ")");

    if errors = 0 then
      report "METRIC PACKET MANAGER TEST PASSED" severity note;
    else
      report "METRIC PACKET MANAGER TEST FAILED: " & integer'image(errors) & " error(s)" severity failure;
    end if;
    finish;
    wait;
  end process stim;

end architecture sim;
