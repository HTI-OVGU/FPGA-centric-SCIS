--------------------------------------------------------------------------------
-- tb_telemetry - telemetry_sender passthrough of a metric packet (no interlock).
--
-- Drives a 9-byte packet into s_axis (interlock low, no almost-full) and checks
-- it appears unchanged on m_axis with tlast on the 9th beat. Exposes the
-- incomplete-sensitivity-list bug in the combinational output mux (which latches
-- the first byte and repeats it in simulation).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_telemetry is
end entity tb_telemetry;

architecture sim of tb_telemetry is
  constant CLK_PERIOD : time := 25 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal s_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal s_last  : std_logic := '0';
  signal s_valid : std_logic := '0';
  signal s_ready : std_logic;
  signal s_user  : std_logic_vector(2 downto 0) := (others => '0');

  signal m_data  : std_logic_vector(7 downto 0);
  signal m_last  : std_logic;
  signal m_valid : std_logic;
  signal m_ready : std_logic := '1';
  signal m_user  : std_logic_vector(2 downto 0);

  signal interlock : std_logic := '0';

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

  dut : entity work.telemetry_sender(Behavioral)
    port map (
      clk => clk, reset => rst,
      m_axis_data => m_data, m_axis_valid => m_valid, m_axis_last => m_last,
      m_axis_ready => m_ready, m_axis_user => m_user,
      s_axis_data => s_data, s_axis_last => s_last, s_axis_valid => s_valid,
      s_axis_ready => s_ready, s_axis_user => s_user,
      interlock => interlock, almost_full_vector => x"00"
    );

  capture : process (clk)
    variable idx : integer := 0;
  begin
    if rising_edge(clk) then
      if m_valid = '1' and m_ready = '1' then
        if idx <= 8 then cap(idx) <= m_data; end if;
        if m_last = '1' and last_pos < 0 then last_pos <= idx; end if;
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

    -- AXIS master: present byte, advance only when accepted (s_ready high)
    for i in 0 to 8 loop
      s_data  <= PKT(i);
      s_user  <= "000";
      if i = 8 then s_last <= '1'; else s_last <= '0'; end if;
      s_valid <= '1';
      loop
        wait until rising_edge(clk);
        exit when s_ready = '1';
      end loop;
    end loop;
    s_valid <= '0';
    s_last  <= '0';

    wait for 3 us;

    report "TLM OUT[0..8] = "
         & hx(cap(0)) & " " & hx(cap(1)) & " " & hx(cap(2)) & " "
         & hx(cap(3)) & " " & hx(cap(4)) & " " & hx(cap(5)) & " "
         & hx(cap(6)) & " " & hx(cap(7)) & " " & hx(cap(8))
         & " | n=" & integer'image(cap_n)
         & " tlast@" & integer'image(last_pos);

    chk(cap_n = 9, "TLM: expected exactly 9 beats out, got " & integer'image(cap_n));
    for i in 0 to 8 loop
      chk(cap(i) = PKT(i), "TLM byte " & integer'image(i) & " mismatch (got "
          & hx(cap(i)) & " exp " & hx(PKT(i)) & ")");
    end loop;
    chk(last_pos = 8, "TLM: tlast not on the 9th beat (got @" & integer'image(last_pos) & ")");

    if errors = 0 then
      report "TELEMETRY_SENDER PASSTHROUGH TEST PASSED" severity note;
    else
      report "TELEMETRY_SENDER PASSTHROUGH TEST FAILED: " & integer'image(errors) & " error(s)" severity failure;
    end if;
    finish;
    wait;
  end process stim;

end architecture sim;
