library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
-- Dual Port RAM (WRITE_THROUGH)
entity bram_dp_write_through is
  generic (
    DATA_WIDTH : integer := 18;
    ADDR_WIDTH : integer := 6
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
architecture rtl of bram_dp_write_through is
  type ram is array (0 to (2 ** ADDR_WIDTH) - 1) of std_logic_vector(DATA_WIDTH - 1 downto 0);
  shared variable memory : ram := (others => (others => '0'));
begin
  port_a : process (clka)
  begin
    if rising_edge(clka) then
      if (wea = '1') then
        memory(to_integer(unsigned(addra))) := dia;
        doa <= dia;
      else
        doa <= memory(to_integer(unsigned(addra)));
      end if;
    end if;
  end process port_a;
  port_b : process (clkb)
  begin
    if rising_edge(clkb) then
      if (web = '1') then
        memory(to_integer(unsigned(addrb))) := dib;
        dob <= dib;
      else
        dob <= memory(to_integer(unsigned(addrb)));
      end if;
    end if;
  end process port_b;
end architecture;