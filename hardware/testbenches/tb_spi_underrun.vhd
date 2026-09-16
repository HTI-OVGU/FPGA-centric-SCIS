-- Does spi_master survive a starved TX source mid-transaction?
--
-- The transaction starts as soon as ONE byte is in the internal TX payload
-- FIFO, so any later gap in the source can drain that FIFO while CS is still
-- low. When that happens the byte-boundary reload at spi_master.vhd:206 takes
-- tx_payload_data regardless of tx_payload_valid_buffer, and sclk keeps
-- toggling (:267) -- so the held byte is shifted out a second time and every
-- byte behind it slides by one.
--
-- That is exactly the corruption measured on hardware once metric batching was
-- enabled: a datagram of N metrics came back with N-2 records displaced by one
-- byte. A single-metric datagram has no internal boundary to starve on, which
-- is why it only appeared with batching.
--
-- This drives a known byte sequence with deliberate starvation windows, samples
-- MOSI on the SPI clock, and requires the captured stream to equal the driven
-- stream exactly -- same bytes, same count.
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity tb_spi_underrun is
end entity;

architecture sim of tb_spi_underrun is
  constant CLK_PERIOD : time    := 10 ns;
  constant N_BYTES    : integer := 8;

  type byte_array is array (0 to N_BYTES - 1) of std_logic_vector(7 downto 0);
  -- Distinct values: a duplicated byte has to be visible as a duplicate.
  constant TEST_DATA : byte_array :=
    (x"A0", x"A1", x"A2", x"A3", x"A4", x"A5", x"A6", x"A7");

  -- Idle clocks inserted BEFORE writing that byte. A byte occupies 16 clocks on
  -- the wire, so 100 clocks is comfortably longer than anything still queued
  -- and guarantees the FIFO is empty when the boundary arrives.
  type gap_array is array (0 to N_BYTES - 1) of integer;
  constant GAPS : gap_array := (0, 0, 0, 100, 0, 0, 100, 0);

  signal clk    : std_logic := '0';
  signal reset  : std_logic := '1';
  signal tdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal tvalid : std_logic := '0';
  signal tlast  : std_logic := '0';
  signal tready : std_logic;

  signal rdata    : std_logic_vector(7 downto 0);
  signal rvalid   : std_logic;
  signal rlast    : std_logic;
  signal miso     : std_logic := '0';
  signal mosi     : std_logic;
  signal sclk     : std_logic;
  signal cs       : std_logic;
  signal spi_busy : std_logic;

  constant CAP_MAX : integer := 64;
  type cap_array is array (0 to CAP_MAX - 1) of std_logic_vector(7 downto 0);
  signal captured   : cap_array := (others => (others => '0'));
  signal captured_n : integer   := 0;
begin

  clk <= not clk after CLK_PERIOD / 2;

  dut : entity work.spi_master
    port map (
      tdata => tdata, rdata => rdata,
      mosi => mosi, miso => miso, sclk => sclk, cs => cs,
      clk => clk, reset => reset, spi_busy => spi_busy,
      tvalid => tvalid, tready => tready, tlast => tlast,
      rvalid => rvalid, rready => '1', rlast => rlast);

  -- Reassemble MOSI into bytes, MSB first, sampled on the rising SPI edge.
  capture : process
    variable bit_count : integer := 0;
    variable acc       : std_logic_vector(7 downto 0) := (others => '0');
  begin
    wait until rising_edge(sclk);
    acc       := acc(6 downto 0) & mosi;
    bit_count := bit_count + 1;
    if bit_count = 8 then
      if captured_n < CAP_MAX then
        captured(captured_n) <= acc;
        captured_n           <= captured_n + 1;
      end if;
      bit_count := 0;
    end if;
  end process;

  stim : process
    variable errors : integer := 0;
    variable n      : integer;
  begin
    reset <= '1';
    wait for 100 ns;
    wait until rising_edge(clk);
    reset <= '0';
    wait until rising_edge(clk);

    for i in 0 to N_BYTES - 1 loop
      for g in 1 to GAPS(i) loop        -- starvation window
        wait until rising_edge(clk);
      end loop;
      tdata  <= TEST_DATA(i);
      tvalid <= '1';
      if i = N_BYTES - 1 then
        tlast <= '1';
      else
        tlast <= '0';
      end if;
      wait until rising_edge(clk) and tready = '1';
      tvalid <= '0';
      tlast  <= '0';
    end loop;

    -- Let the tail drain and the transaction close.
    for t in 1 to 4000 loop
      wait until rising_edge(clk);
    end loop;

    n := captured_n;
    report "driven " & integer'image(N_BYTES) & " bytes, captured "
           & integer'image(n);

    if n /= N_BYTES then
      errors := errors + 1;
      report "BYTE COUNT MISMATCH: expected " & integer'image(N_BYTES)
             & ", got " & integer'image(n)
             & " -- the bus kept clocking while the source was starved"
             severity note;
    end if;

    for i in 0 to N_BYTES - 1 loop
      if i < n then
        if captured(i) /= TEST_DATA(i) then
          errors := errors + 1;
          report "BYTE " & integer'image(i) & ": expected "
                 & to_hstring(TEST_DATA(i)) & " got " & to_hstring(captured(i))
                 severity note;
        end if;
      end if;
    end loop;

    if errors = 0 then
      report "SPI UNDERRUN TEST PASSED" severity note;
    else
      report "SPI UNDERRUN TEST FAILED: " & integer'image(errors)
             & " error(s)" severity note;
    end if;
    std.env.stop;
  end process;

end architecture;
