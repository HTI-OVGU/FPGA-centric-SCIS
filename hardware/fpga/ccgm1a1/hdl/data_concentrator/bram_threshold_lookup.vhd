library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
-- Dual Port RAM (NO_CHANGE)
entity threshold_lookup_bram is
  generic (
    DATA_WIDTH : integer := 32;
    ADDR_WIDTH : integer := 11
  );
  port (
    wea   : in std_logic;
    web   : in std_logic;
    clka  : in std_logic;
    clkb  : in std_logic;
    dia   : in std_logic_vector(DATA_WIDTH - 1 downto 0);
    dib   : in std_logic_vector(DATA_WIDTH - 1 downto 0);
    addra : in std_logic_vector(ADDR_WIDTH - 1 downto 0);
    addrb : in std_logic_vector(ADDR_WIDTH - 1 downto 0);
    doa   : out std_logic_vector(DATA_WIDTH - 1 downto 0);
    dob   : out std_logic_vector(DATA_WIDTH - 1 downto 0)
  );
end entity;
architecture rtl of threshold_lookup_bram is
  type ram is array (0 to (2 ** ADDR_WIDTH) - 1) of std_logic_vector(DATA_WIDTH - 1 downto 0);
  shared variable memory : ram := (
    0 => x"00000000",      -- value at address 0
    1 => x"0000FABC",     -- value at address 1
    2 => x"00000000",      -- value at address 2 (example)
    3 => x"DEADBEEF",
    98 => x"00001010",
    99 => x"00000015",
    192 => x"00000013",
    193 => x"00000020",
    640 => x"00000000", --PSUs
    641 => x"000FA000",
    536 => x"00000000", -- COIL
    537 => x"00002800",
    560 => x"00000000", -- FAN speed
    561 => x"000F4000",
    664 => x"00000000", -- system load
    665 => x"00019000",
    2046 => x"FFFFFFFF",
    2047 => x"FFFFFFFF",
    others => (others => '0')  -- fill all remaining addresses with '0'
  );
begin
  port_a: process(clka)
    begin
      if rising_edge(clka) then
        if (wea = '1') then
          memory(to_integer(unsigned(addra))) := dia;
        else
          doa <= memory(to_integer(unsigned(addra)));
        end if;
      end if;
    end process port_a;
  port_b: process(clkb)
    begin
      if rising_edge(clkb) then
        if (web = '1') then
          memory(to_integer(unsigned(addrb))) := dib;
        else
          dob <= memory(to_integer(unsigned(addrb)));
        end if;
      end if;
  end process port_b;
end architecture;

