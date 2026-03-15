-- AXI-Stream record definition
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package metric_axi_stream_pkg is

  constant C_AXIS_TDATA_WIDTH : integer := 8;
  constant C_AXIS_TUSER_WIDTH : integer := 3;

  type metric_axi_stream_t is record
    tdata  : std_logic_vector(C_AXIS_TDATA_WIDTH-1 downto 0);
    tuser  : std_logic_vector(C_AXIS_TUSER_WIDTH-1 downto 0);
    tvalid : std_logic;
    tlast  : std_logic;
  end record metric_axi_stream_t;

  type metric_axi_stream_array_t is array (natural range <>) of metric_axi_stream_t;

end package metric_axi_stream_pkg;