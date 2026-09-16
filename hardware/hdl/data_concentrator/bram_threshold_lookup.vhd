library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.threshold_tables_pkg.all;
-- Dual Port RAM (NO_CHANGE)
-- Threshold contents come from the INIT_TABLE generic (per-channel tables live
-- in threshold_tables_pkg). DATA_WIDTH/ADDR_WIDTH must stay 32/11 to match
-- threshold_table_t (2048 x 32 bit).
entity threshold_lookup_bram is
  generic (
    DATA_WIDTH : integer := 32;
    ADDR_WIDTH : integer := 11;
    INIT_TABLE : threshold_table_t := ZERO_THRESHOLD_TABLE
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
  shared variable memory : threshold_table_t := INIT_TABLE;
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
