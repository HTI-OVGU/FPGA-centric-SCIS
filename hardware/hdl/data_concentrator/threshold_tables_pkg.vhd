library ieee;
use ieee.std_logic_1164.all;

-- Compile-time threshold lookup tables, one per data-concentrator input channel.
--
-- Each table holds 1024 {lower, upper} pairs of signed Q22.10 values addressed
-- by the 10 most significant bits of the 16-bit metric identifier:
--   address = metric_id(15 downto 6) & '0'  -> lower threshold
--   address = metric_id(15 downto 6) & '1'  -> upper threshold
--
-- Those 10 bits are the slow-control DeviceTypeID; the low 6 bits (Device No)
-- are NOT part of the address, so every instance of a type -- all 64 LNA
-- channels, all 4 ADC boards -- shares one {lower, upper} pair:
--
--   | 'V01' 24 bit | DeviceTypeID 10 bit | Device No 6 bit | value 32 bit |
--
-- The limits below are the Critical_Low / Critical_High columns of
--   software_infrastructure/Slow_control_protocol_example.csv
-- converted to Q22.10. Regenerate the entries after editing that CSV with
--   python3 software_infrastructure/MetricPacketServer/build_slow_control_catalog.py --vhdl
-- (add --vhdl-transfer=CAN for the CAN channel), and paste the output below.
-- The same CSV drives slow_control_catalog.json, so the FPGA interlock and the
-- Grafana dashboards enforce and display exactly the same numbers.
--
-- Unspecified entries default to zero for BOTH thresholds, so any non-zero
-- metric value asserts a protective interlock until a safe operating area is
-- explicitly defined (fail-safe default, thesis section 5.4.1). The parameters
-- whose Critical_* columns are still blank in the CSV are therefore left
-- commented out below rather than given an invented limit -- see the
-- "LIMITS NOT YET DEFINED" block.
package threshold_tables_pkg is

  -- 1024 device slots x {lower, upper} = 2048 words of 32 bit
  constant THRESHOLD_TABLE_DEPTH : natural := 2048;
  type threshold_table_t is array (0 to THRESHOLD_TABLE_DEPTH - 1) of std_logic_vector(31 downto 0);
  type threshold_table_array_t is array (natural range <>) of threshold_table_t;

  constant ZERO_THRESHOLD_TABLE : threshold_table_t := (others => (others => '0'));

  -- Channel 0: Ethernet/UDP metric sources (identifier chosen by the sender).
  -- Carries the whole slow-control parameter list, because every parameter can
  -- also be injected over UDP (testing_scripts/simulate_devices.py does exactly
  -- that), and the limits must not depend on the transport used.
  constant ETH_THRESHOLD_TABLE : threshold_table_t := (
    -- ---- Slow-control parameters (generated from Slow_control_protocol_example.csv) ----
    0    => x"00000400", -- Emergency_Stop, SC_online (Safety): must stay asserted (1.0)
    1    => x"00000400",
    2    => x"00003C00", -- Room_Temperature (Environment): 15 .. 30 degC
    3    => x"00007800",
    4    => x"00005000", -- Room_Humidity (Environment): 20 .. 80 %RH
    5    => x"00014000",
    20   => x"00032000", -- Main_Voltage (DAQ Power Supply 1): 200 .. 260 V
    21   => x"00041000",
    402  => x"00000000", -- VCO00..63_Vtune (Mixer / VCO): 0 .. 1 V
    403  => x"00000400", --   (CSV gives only a warning band for Vtune; used as the limit)
    1800 => x"00000C00", -- ADC1..4_3V3 (ADC): 3.0 .. 3.6 V
    1801 => x"00000E66",
    1802 => x"00000000", -- ADC1..4_FPGA_Temp (ADC): 0 .. 90 degC
    1803 => x"00016800",
    1804 => x"00000C00", -- DAC1..4_3V3 (DAC): 3.0 .. 3.6 V
    1805 => x"00000E66",
    1806 => x"00000000", -- DAC1..4_FPGA_Temp (DAC): 0 .. 90 degC
    1807 => x"00016800",
    2046 => x"00001200", -- SC_FPGA_V_Core (Slow Control): 4.5 .. 5.5 V
    2047 => x"00001600",

    -- ---- LIMITS NOT YET DEFINED ----------------------------------------------
    -- The Critical_Low/High columns are blank for these parameters, so they keep
    -- the fail-safe zero entry: any non-zero reading trips the interlock until
    -- the responsible engineer fills the CSV in. The commented values are only a
    -- +-20% band around Nominal_Value -- uncomment ONLY once the real safe
    -- operating area has been agreed, and put it in the CSV at the same time.
    -- 200  => x"000005C3", -- LNA00..63_V1   (Fabse):  1.44 .. 2.16 V     (nominal 1.8 V)
    -- 201  => x"000008A4",
    -- 202  => x"00000010", -- LNA00..63_I1   (Fabse):  0.016 .. 0.024 A   (nominal 0.02 A)
    -- 203  => x"00000019",
    -- 204  => x"0000499A", -- LNA00..63_Temp (Fabse):  18.4 .. 27.6 degC  (nominal 23 degC)
    -- 205  => x"00006E66",
    -- 400  => x"000003D7", -- VCO00..63_V1   (Zeyi):   0.96 .. 1.44 V     (nominal 1.2 V)
    -- 401  => x"000005C3",
    -- 404  => x"0000499A", -- VCO00..63_Temp (Zeyi):   18.4 .. 27.6 degC  (nominal 23 degC)
    -- 405  => x"00006E66",
    -- 600  => x"0003F333", -- PA00..63_V1    (Alicia): 252.8 .. 379.2 V   (nominal 316 V)
    -- 601  => x"0005ECCD",
    -- 602  => x"00001429", -- PA00..63_I1    (Alicia): 5.04 .. 7.56 A     (nominal 6.3 A)
    -- 603  => x"00001E3D",
    -- 604  => x"0000499A", -- PA00..63_Temp  (Alicia): 18.4 .. 27.6 degC  (nominal 23 degC)
    -- 605  => x"00006E66",
    -- 800  => x"00002666", -- SW00..63_I(Vctrl1) (Sanaul): 9.6 .. 14.4 mA (nominal 12 mA)
    -- 801  => x"0000399A",
    -- 802  => x"00002666", -- SW00..63_I(Vctrl2) (Sanaul): 9.6 .. 14.4 mA (nominal 12 mA)
    -- 803  => x"0000399A",

    -- ---- Bench fixtures (not slow-control parameters) -------------------------
    -- Kept so the existing UDP bench setups and the ch0 drain/threshold
    -- regression sims keep their limits. DeviceTypeIDs 49/96/268/280/320/332 are
    -- not used by the CSV, so they cannot collide with a real parameter.
    98   => x"00001010", -- DeviceTypeID 49  (bench fixture) -- WARNING: this pair is
    99   => x"00000015", --   INVERTED (lower 4.0156 > upper 0.0205), so every reading
                         --   from device type 49 trips the interlock unconditionally.
                         --   Pre-existing; left untouched because the intent is unclear.
    192  => x"00000013", -- DeviceTypeID 96  (bench fixture)
    193  => x"00000020",
    536  => x"00000000", -- COIL        (identifier 0x4300): 0 .. 10.0 A
    537  => x"00002800",
    560  => x"00000000", -- FAN speed   (identifier 0x4600): 0 .. 976.0 RPM
    561  => x"000F4000",
    640  => x"00000000", -- PSU         (identifier 0x5000): 0 .. 1000.0 V;
    641  => x"000FA000", --   also used by the ch0 drain/threshold regression sims
    664  => x"00000000", -- system load (identifier 0x5300): 0 .. 100.0 %
    665  => x"00019000",
    others => (others => '0')
  );

  -- Channel 1: CAN metric sources. The 11-bit CAN ID is left-aligned into the
  -- identifier, so device index == CAN ID (see can_metric_adapter) -- i.e. the
  -- CAN ID *is* the DeviceTypeID. Only the parameters the CSV marks as
  -- "Transfer protocol = CAN" are listed here; everything else reaching this
  -- channel hits the fail-safe zero entry on purpose.
  constant CAN_THRESHOLD_TABLE : threshold_table_t := (
    -- ---- Slow-control parameters carried over CAN ----
    2   => x"00003C00", -- Room_Temperature (CAN ID 1): 15 .. 30 degC
    3   => x"00007800",
    4   => x"00005000", -- Room_Humidity    (CAN ID 2): 20 .. 80 %RH
    5   => x"00014000",

    -- ---- Bench fixtures (pre-CSV CAN test node) ----
    536 => x"00000000", -- COIL        (CAN ID 268): 0 .. 10.0 A
    537 => x"00002800",
    560 => x"00000000", -- FAN speed   (CAN ID 280): 0 .. 976.0 RPM
    561 => x"000F4000",
    640 => x"00000000", -- PSU         (CAN ID 320): 0 .. 1000.0 V
    641 => x"000FA000",
    664 => x"00000000", -- system load (CAN ID 332): 0 .. 100.0 %
    665 => x"00019000",
    others => (others => '0')
  );

  -- Table per data-concentrator input channel (index = channel number, one per
  -- possible priority/socket). Channels without an explicit table fall back to
  -- the fail-safe zero table.
  constant CHANNEL_THRESHOLD_TABLES : threshold_table_array_t(0 to 7) := (
    0      => ETH_THRESHOLD_TABLE,
    1      => CAN_THRESHOLD_TABLE,
    others => ZERO_THRESHOLD_TABLE
  );

end package threshold_tables_pkg;
