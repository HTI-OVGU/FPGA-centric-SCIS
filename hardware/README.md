
### VHDL workflow

The FPGA/CCGM1A1 directory contains the VHDL source files, testbenches, constraints and a makefile to build the project for the CologneChip GateMate M1A1 FPGA Board.

Tools within the [OSS-CAD-Suite](https://github.com/YosysHQ/oss-cad-suite-build/releases) by YoysyHQ (tested with Build 21-01-2026) have been used for synthesis, implementation, bitstream packing and bitstream uploading.

![VHDL workflow](../etc/figure/Workflow.png)

Building the data concentrator project for two W5500s connected to the PMOD pins:

Inside the root directory of the OSS-CAD-Suite

```bash
source environment
```

Inside the CCGM1A1 folder:

```bash
make all
```

Test W5500 functionality:

```bash
make w5500_all
```

GHDL + GTKwave simulations:

```bash
make sim_spimaster
make sim_w5500
make sim_dc
make sim_all
make sim_can_dc       # CAN frame -> adapter -> data concentrator -> interlock trip/clear (view: make view_can_dc)
make sim_can_ack      # ACK transmit path: good-CRC frame -> dominant ACK on can_tx, bad-CRC -> silent
make sim_drain_suite  # layered telemetry-drain regression: FIFO -> manager -> threshold -> telemetry -> full DC
```

## Supervisory Monitoring Unit / Data Concentrator

![Data Concentrator System Design](../etc/figure/Data%20Concentrator.png)

Features: 
- 8-bit data AXI-stream based data flow
- Low latency deterministic interlock assertion in the Threshold Logic Units
- Glitch filter with hysteresis behavior for external interlock signals
- 8 priority levels (encoded in 3 bit USER field)
- sending an "INTERLOCK" or "ALMOSTFULL" alert by the Telemetry Sender

### Threshold Lookup Memory

The compile-time tables live in `hdl/data_concentrator/threshold_tables_pkg.vhd`. They are
**generated from the slow-control parameter list**
(`software_infrastructure/Slow_control_protocol_example.csv`), so the FPGA interlock and the
Grafana dashboards enforce and display the same `Critical_Low` / `Critical_High` numbers:

```bash
python3 ../../../software_infrastructure/MetricPacketServer/build_slow_control_catalog.py --vhdl                # channel 0 (UDP)
python3 ../../../software_infrastructure/MetricPacketServer/build_slow_control_catalog.py --vhdl-transfer=CAN   # channel 1 (CAN)
```

The BRAM address is `metric_id(15 downto 6)`, i.e. the **DeviceTypeID alone** — the Device№ is
not part of the address, so all 64 channels of a type share one `{lower, upper}` pair.
Unspecified entries default to zero for both limits, so any non-zero value asserts a
protective interlock until a safe operating area is explicitly defined (fail-safe default).

For a single ad-hoc entry, `threshold_address_generator.py` converts a float pair to the two
Q22.10 words and their addresses:

```bash
python3 threshold_address_generator.py
```

## CAN metric channel

`hdl/can/` contains a self-contained CAN metric source (`can_metric_source` wrapping the
vendored `can_node` receiver core and the `can_metric_adapter`):

- **Active node** (`ACK_DRIVE => true`): `can_rx` on `IO_NB_B4` (PMOD B pin 7), `can_tx` on
  `IO_NB_B5` (PMOD B pin 8). The core drives a dominant ACK for every accepted frame, so the
  remote controller sees its frames acknowledged instead of retransmitting until it goes
  error-passive.
- Three wiring configurations, selected by two generics in `top.vhd` (full rationale in the
  comment block above the `can_source` instance) — pick **exactly one**. The CCF line is the
  same for all three: `Net "can_tx" Loc = "IO_NB_B5" | SLEW=slow | DRIVE=9;` — nextpnr takes
  the direction and the tri-state from the netlist. (Do **not** use the legacy `Pin_triout`
  keyword the CCF header lists; that is Cologne Chip `p_r` syntax and the
  nextpnr-himbaechel parser rejects it.)

  | Config | `ECHO_RX` | `TX_OPEN_DRAIN` | Wiring | `can_tx` pad |
  |---|---|---|---|---|
  | (A) two wires, no transceiver | `true` | `false` | STM32 TX → pin 7, pin 8 → STM32 RX | push-pull |
  | **(B) shared wire + pull-up** ← current | `false` | `true` | pins 7, 8, PD0, PD1 on one node, 1k–2.2k to 3V3 | tri-state (`CC_TOBUF`) |
  | (C) TJA1051T/3 transceiver | `false` | `false` | RXD → pin 7, pin 8 → TXD | push-pull |

  `ECHO_RX` mirrors `can_rx` onto `can_tx` so a transceiver-less controller's bit monitoring
  sees its own bits come back. It **must** be false on a shared or transceiver-backed bus —
  there it is positive feedback that latches the bus dominant.
- 125 kbps, standard 11-bit identifiers, 75 % sample point, CRC-15 checked.
  Bit timing is derived from the 30 MHz system clock (`ClockFrequencyHz` generic in `top.vhd`
  must track the CC_PLL `OUT_CLK`).
- Each valid frame becomes a 9-byte V01 Metric Packet on Data Concentrator input channel 1
  (`CAN_TUSER => "001"`). The CAN ID *is* the DeviceTypeID (`metric_id = CAN ID << 6`, so
  Device№ is always 0): threshold memory addresses are `2*ID` (lower) and `2*ID + 1` (upper).
- LED D8 blinks on every received frame (active-low).