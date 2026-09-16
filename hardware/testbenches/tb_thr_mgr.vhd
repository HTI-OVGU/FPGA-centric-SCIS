--------------------------------------------------------------------------------
-- tb_thr_mgr - threshold_logic -> metric_packet_manager composition.
--
-- Each stage passes alone; the full DC does not. This chains the two stages the
-- DC puts between input and telemetry_sender: a real V01 packet into
-- threshold_logic, its forwarded output into manager stream 0 (stream 1 idle),
-- manager m_axis captured with tready high. Isolates the threshold->manager
-- handshake (FWFT buffer_fifo feeding the manager skid, with bubbles near-empty).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;
use work.metric_axi_stream_pkg.all;

entity tb_thr_mgr is
end entity tb_thr_mgr;

architecture sim of tb_thr_mgr is
  constant CLK_PERIOD : time := 25 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  -- r-side into threshold_logic
  signal rdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal rvalid : std_logic := '0';
  signal rlast  : std_logic := '0';
  signal rready : std_logic;
  signal ruser  : std_logic_vector(2 downto 0) := (others => '0');

  -- threshold_logic -> manager stream 0
  signal thr_axis   : metric_axi_stream_t;
  signal interlock  : std_logic;
  signal deassert   : std_logic := '0';

  -- manager
  signal s_axis   : metric_axi_stream_array_t(0 to 1);
  signal s_tready : std_logic_vector(1 downto 0);
  signal m_axis   : metric_axi_stream_t;
  signal m_tready : std_logic := '1';
  signal af       : std_logic_vector(7 downto 0);

  type barr is array (0 to 8) of std_logic_vector(7 downto 0);
  constant PKT : barr :=
    (x"56", x"30", x"31", x"50", x"00", x"00", x"07", x"D0", x"00");

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

  u_thr : entity work.threshold_logic(Behavioral)
    generic map (
      -- channel-0 table: holds the PSU pair (index 320: 0 .. 1000.0)
      INIT_TABLE => work.threshold_tables_pkg.ETH_THRESHOLD_TABLE
    )
    port map (
      clk => clk, reset => rst,
      tdata => thr_axis.tdata, tvalid => thr_axis.tvalid, tlast => thr_axis.tlast,
      tready => s_tready(0), tuser => thr_axis.tuser,
      rdata => rdata, rlast => rlast, rvalid => rvalid, rready => rready, ruser => ruser,
      interlock => interlock, deassert_interlock => deassert
    );

  s_axis(0) <= thr_axis;
  s_axis(1) <= (tdata => (others => '0'), tuser => (others => '0'),
               tvalid => '0', tlast => '0');

  u_mgr : entity work.metric_packet_manager(Behavioral)
    generic map (metric_input_stream_amount => 2)
    port map (
      clk => clk, reset => rst,
      s_axis => s_axis, s_axis_tready => s_tready,
      m_axis => m_axis, m_axis_tready => m_tready,
      almost_full_vector => af
    );

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
    rst <= '1';
    for i in 1 to 6 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    for i in 0 to 8 loop
      rdata  <= PKT(i);
      ruser  <= "000";
      if i = 8 then rlast <= '1'; else rlast <= '0'; end if;
      rvalid <= '1';
      loop
        wait until rising_edge(clk);
        exit when rready = '1';
      end loop;
    end loop;
    rvalid <= '0';
    rlast  <= '0';

    wait for 8 us;

    report "THR->MGR OUT[0..8] = "
         & hx(cap(0)) & " " & hx(cap(1)) & " " & hx(cap(2)) & " "
         & hx(cap(3)) & " " & hx(cap(4)) & " " & hx(cap(5)) & " "
         & hx(cap(6)) & " " & hx(cap(7)) & " " & hx(cap(8))
         & " | n=" & integer'image(cap_n)
         & " tlast@" & integer'image(last_pos);

    chk(cap_n = 9, "THR->MGR: expected exactly 9 beats out, got " & integer'image(cap_n));
    for i in 0 to 8 loop
      chk(cap(i) = PKT(i), "THR->MGR byte " & integer'image(i) & " mismatch (got "
          & hx(cap(i)) & " exp " & hx(PKT(i)) & ")");
    end loop;
    chk(last_pos = 8, "THR->MGR: tlast not on the 9th beat (got @" & integer'image(last_pos) & ")");

    if errors = 0 then
      report "THRESHOLD->MANAGER TEST PASSED" severity note;
    else
      report "THRESHOLD->MANAGER TEST FAILED: " & integer'image(errors) & " error(s)" severity failure;
    end if;
    finish;
    wait;
  end process stim;

end architecture sim;
