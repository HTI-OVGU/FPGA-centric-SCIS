--------------------------------------------------------------------------------
-- tb_dc_ch0_drain - does the W5500 channel (0) drain a FULL packet at N=2?
--
-- This is the case the CAN bench never simulated. On the PYNQ the Data
-- Concentrator runs input_channel_amount => 2 (ch0 = W5500/UDP, ch1 = CAN).
-- The GateMate that worked ran N=1, so the N=2 arbiter path has never been
-- exercised on working hardware. Here we drive ONE clean 9-byte V01 Metric
-- Packet straight into channel 0 (channel 1 held idle, mimicking "no CAN bus")
-- and check the DC telemetry output reproduces it FAITHFULLY with tlast.
--
-- Unlike tb_can_to_dc, this bench DOES assert the forwarded byte content and the
-- position of tlast, and it prints the captured output bytes so a garbled drain
-- (e.g. "0x56 repeated / final beat dropped") is visible directly.
--
--   Packet: "V01" + identifier 0x5000 + value 500.0 (Q22.10 0x0007D000).
--   identifier(15:6) = 320 -> threshold-BRAM device index 320,
--   which bram_threshold_lookup sets to lower=0, upper=0x000FA000 (1000.0),
--   so 500.0 is in range -> NO interlock; a second 2000.0 packet -> interlock.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;
use work.metric_axi_stream_pkg.all;

entity tb_dc_ch0_drain is
  generic (N : positive := 2);                    -- DC input_channel_amount (override with -gN=1)
end entity tb_dc_ch0_drain;

architecture sim of tb_dc_ch0_drain is
  constant CLK_PERIOD : time := 25 ns;            -- 40 MHz, matches top.vhd clk0

  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';                -- active-high

  signal dc_in        : metric_axi_stream_array_t(N-1 downto 0);
  signal dc_in_ready  : std_logic_vector(N-1 downto 0);
  signal dc_tdata     : std_logic_vector(7 downto 0);
  signal dc_tvalid    : std_logic;
  signal dc_tlast     : std_logic;
  signal dc_tuser     : std_logic_vector(2 downto 0);
  signal dc_tready    : std_logic := '1';         -- downstream always ready
  signal dc_interlock : std_logic;
  signal deassert     : std_logic := '0';

  type byte_arr is array (0 to 8) of std_logic_vector(7 downto 0);
  -- in-range packet: "V01" + ID 0x5000 (device index 320) + 500.0 (Q22.10)
  constant PKT_OK  : byte_arr :=
    (x"56", x"30", x"31", x"50", x"00", x"00", x"07", x"D0", x"00");
  -- out-of-range packet: same ID, value 2000.0 (Q22.10 0x001F4000) -> interlock
  constant PKT_HI  : byte_arr :=
    (x"56", x"30", x"31", x"50", x"00", x"00", x"1F", x"40", x"00");

  -- output capture (independent of tlast; record up to 16 beats + tlast position)
  signal cap_arm   : std_logic := '0';
  signal cap       : byte_arr := (others => (others => '0'));
  signal cap_n     : integer := 0;
  signal last_pos  : integer := -1;
  signal cap_tuser : std_logic_vector(2 downto 0) := (others => '0');

  function hx(b : std_logic_vector(7 downto 0)) return string is
    constant d : string(1 to 16) := "0123456789ABCDEF";
    variable v : integer := to_integer(unsigned(b));
  begin
    return d(1 + v/16) & d(1 + (v mod 16));
  end function;

begin

  clk <= not clk after CLK_PERIOD / 2;

  u_dc : entity work.data_concentrator(Behavioral)
    generic map (input_channel_amount => 2)
    port map (
      clk                  => clk,
      reset                => reset,
      tdata                => dc_tdata,
      tvalid               => dc_tvalid,
      tlast                => dc_tlast,
      tready               => dc_tready,
      tuser                => dc_tuser,
      s_axis               => dc_in,
      s_axis_ready         => dc_in_ready,
      interlock            => dc_interlock,
      deassert_interlock   => deassert,
      ext_interlock_source => '0'
    );

  -- every channel except 0 held idle (e.g. CAN slot on a board with no CAN traffic).
  -- For N=1 the range 1..0 is null, so nothing is generated.
  gen_idle : for ch in 1 to N-1 generate
    dc_in(ch) <= (tdata => (others => '0'), tuser => (others => '0'),
                  tvalid => '0', tlast => '0');
  end generate;

  -- capture: log each accepted output beat + remember where tlast first lands
  capture : process (clk)
    variable idx : integer := 0;
  begin
    if rising_edge(clk) then
      if cap_arm = '0' then
        idx := 0;
      elsif dc_tvalid = '1' and dc_tready = '1' then
        if idx < 16 then
          if idx <= 8 then cap(idx) <= dc_tdata; end if;
          if dc_tlast = '1' and last_pos < 0 then last_pos <= idx; end if;
          cap_tuser <= dc_tuser;
          idx       := idx + 1;
          cap_n     <= idx;
        end if;
      end if;
    end if;
  end process capture;

  stimulus : process
    variable errors : integer := 0;

    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then
        report msg severity error;
        errors := errors + 1;
      end if;
    end procedure;

    -- AXIS source: drive a 9-byte packet on channel 0, honouring s_axis_ready(0)
    procedure drive_pkt(p : byte_arr; usr : std_logic_vector(2 downto 0)) is
    begin
      for i in 0 to 8 loop
        dc_in(0).tdata  <= p(i);
        dc_in(0).tuser  <= usr;
        if i = 8 then dc_in(0).tlast <= '1'; else dc_in(0).tlast <= '0'; end if;
        dc_in(0).tvalid <= '1';
        loop
          wait until rising_edge(clk);
          exit when dc_in_ready(0) = '1';
        end loop;
      end loop;
      dc_in(0).tvalid <= '0';
      dc_in(0).tlast  <= '0';
    end procedure;

  begin
    dc_in(0) <= (tdata => (others => '0'), tuser => (others => '0'),
                 tvalid => '0', tlast => '0');
    reset <= '1';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    reset <= '0';
    for i in 1 to 8 loop wait until rising_edge(clk); end loop;

    ----------------------------------------------------------------------------
    -- ONE clean in-range packet on channel 0; channel 1 idle.
    ----------------------------------------------------------------------------
    cap_arm <= '1';
    drive_pkt(PKT_OK, "000");
    wait for 20 us;                                -- traverse FIFO + arbiter + sender

    report "OUT[0..8] = "
         & hx(cap(0)) & " " & hx(cap(1)) & " " & hx(cap(2)) & " "
         & hx(cap(3)) & " " & hx(cap(4)) & " " & hx(cap(5)) & " "
         & hx(cap(6)) & " " & hx(cap(7)) & " " & hx(cap(8))
         & " | n=" & integer'image(cap_n)
         & " tlast@" & integer'image(last_pos)
         & " tuser=" & hx("00000" & cap_tuser);

    check(cap_n >= 9, "DRAIN: fewer than 9 bytes reached the DC output");
    for i in 0 to 8 loop
      check(cap(i) = PKT_OK(i),
            "DRAIN: output byte " & integer'image(i) & " mismatch (got "
            & hx(cap(i)) & " exp " & hx(PKT_OK(i)) & ")");
    end loop;
    check(last_pos = 8, "DRAIN: tlast not on the 9th byte (final beat dropped/misplaced)");
    check(dc_interlock = '0', "DRAIN: interlock wrongly asserted for in-range value");
    cap_arm <= '0';

    ----------------------------------------------------------------------------
    -- Out-of-range packet on channel 0 -> interlock must assert (full value parse).
    ----------------------------------------------------------------------------
    drive_pkt(PKT_HI, "000");
    wait until dc_interlock = '1' for 100 us;
    check(dc_interlock = '1', "DRAIN: interlock did NOT assert for out-of-range value on ch0");

    if errors = 0 then
      report "DC CH0 N=2 DRAIN TEST PASSED" severity note;
    else
      report "DC CH0 N=2 DRAIN TEST FAILED: " & integer'image(errors) & " error(s)"
        severity failure;
    end if;
    finish;
    wait;
  end process stimulus;

end architecture sim;
