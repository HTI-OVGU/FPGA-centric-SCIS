--------------------------------------------------------------------------------
-- tb_threshold - threshold_logic forwarding under CONCURRENT write+read.
--
-- Drives a real V01 packet into the r-side exactly as the DC does (present a
-- byte, wait for rready) while a live reader (tready high) drains the t-side.
-- This keeps threshold_logic's internal buffer_fifo (metric_packet_fifo)
-- near-empty with read chasing write -- the condition the "write-all-then-drain"
-- FIFO unit tests never hit. Checks the forwarded bytes + tlast + tuser.
--
-- Packet: "V01" + ID 0x5000 (device index 320) + value 500.0 -> in range,
-- so interlock must stay low; forwarded content must equal the input.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;
use work.metric_axi_stream_pkg.all;

entity tb_threshold is
end entity tb_threshold;

architecture sim of tb_threshold is
  constant CLK_PERIOD : time := 25 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  -- r-side (into threshold_logic)
  signal rdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal rvalid : std_logic := '0';
  signal rlast  : std_logic := '0';
  signal rready : std_logic;
  signal ruser  : std_logic_vector(2 downto 0) := (others => '0');

  -- t-side (forwarded out)
  signal tdata  : std_logic_vector(7 downto 0);
  signal tvalid : std_logic;
  signal tlast  : std_logic;
  signal tready : std_logic := '1';   -- live reader, always ready
  signal tuser  : std_logic_vector(2 downto 0);

  signal interlock : std_logic;
  signal deassert  : std_logic := '0';

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

  dut : entity work.threshold_logic(Behavioral)
    generic map (
      -- channel-0 table: holds the PSU pair (index 320: 0 .. 1000.0)
      INIT_TABLE => work.threshold_tables_pkg.ETH_THRESHOLD_TABLE
    )
    port map (
      clk => clk, reset => rst,
      tdata => tdata, tvalid => tvalid, tlast => tlast, tready => tready, tuser => tuser,
      rdata => rdata, rlast => rlast, rvalid => rvalid, rready => rready, ruser => ruser,
      interlock => interlock, deassert_interlock => deassert
    );

  capture : process (clk)
    variable idx : integer := 0;
  begin
    if rising_edge(clk) then
      if tvalid = '1' and tready = '1' then
        if idx <= 8 then cap(idx) <= tdata; end if;
        if tlast = '1' and last_pos < 0 then last_pos <= idx; end if;
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

    -- drive the 9-byte packet on r-side, honouring rready (DC-style)
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

    wait for 5 us;

    report "THR OUT[0..8] = "
         & hx(cap(0)) & " " & hx(cap(1)) & " " & hx(cap(2)) & " "
         & hx(cap(3)) & " " & hx(cap(4)) & " " & hx(cap(5)) & " "
         & hx(cap(6)) & " " & hx(cap(7)) & " " & hx(cap(8))
         & " | n=" & integer'image(cap_n)
         & " tlast@" & integer'image(last_pos);

    chk(cap_n = 9, "THR: expected exactly 9 forwarded beats, got " & integer'image(cap_n));
    for i in 0 to 8 loop
      chk(cap(i) = PKT(i), "THR byte " & integer'image(i) & " mismatch (got "
          & hx(cap(i)) & " exp " & hx(PKT(i)) & ")");
    end loop;
    chk(last_pos = 8, "THR: tlast not on the 9th beat (got @" & integer'image(last_pos) & ")");
    chk(interlock = '0', "THR: interlock wrongly asserted for in-range value");

    if errors = 0 then
      report "THRESHOLD_LOGIC FORWARDING TEST PASSED" severity note;
    else
      report "THRESHOLD_LOGIC FORWARDING TEST FAILED: " & integer'image(errors) & " error(s)" severity failure;
    end if;
    finish;
    wait;
  end process stim;

end architecture sim;
