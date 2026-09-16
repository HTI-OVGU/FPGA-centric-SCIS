Tests were conducted using Python 3.13 on a host-computer running Fedora 43.

Installing all packages/libraries:
```bash
pip install -r requirements.txt
```

## Scripts

| Script | Purpose |
|--------|---------|
| `simulate_devices.py` | Scenario-driven simulator that sends as the **real slow-control parameters** from `Slow_control_protocol_example.csv` (safety interlocks, room environment, mains, ADC/DAC rails and temperatures, and the 64-channel LNA/VCO/PA/Switch arrays) with their nominal values, warning/critical bands and measurement intervals. **Sender-only.** See scenarios below. |
| `test_dataconcentrator.py` | Traffic generator — 8 threads simulate 8 anonymous devices (IDs 101–108) sending Gaussian metric values to the RX chip `192.168.2.100:9217-9224`. **Sender-only**, safe to run while the metric server is up. |
| `rtt_test_script.py` | Sends 8192 packets to `192.168.2.100:9217`, times the round-trip until telemetry returns, and plots a histogram to `loopback_delays.svg`. |
| `measure_time_until_alert.py` | Single-shot: sends one packet and reports the round-trip time until the first `INTERLOCK` reply. |
| `random_port_test.py` | Stress test — sends 131072 packets with a Gaussian port distribution and reports per-port loss and `ALMOSTFULL` counts. |
| `test_can_interlock.py` | Observer — polls the metric server's `http://localhost:8001/metrics` to confirm the CAN → interlock → Ethernet path while the STM32 `can_publisher` transmits. Watches any parameter by name (`--device Room_Temperature`, the default) and reads its critical limits from the server rather than hardcoding them. Sends nothing. |

### `simulate_devices.py` scenarios

Every parameter is simulated from its CSV row: identifier `(DeviceTypeID << 6) | DeviceNo`,
nominal value, `Warning_Low/High`, `Critical_Low/High`, and `Measurement_Interval_s`. One
scheduler thread paces all of them, and each subsystem is sent to its own UDP port so
per-port throughput on the admin dashboard is meaningful.

```bash
python simulate_devices.py                                  # all subsystems, everything green
python simulate_devices.py --scenario fault --faults 5      # 5 random devices go warning/critical
python simulate_devices.py --scenario warn                  # everything into its warning band
python simulate_devices.py --scenario trip --duration 5     # everything past its critical limit -> INTERLOCK
python simulate_devices.py --scenario dropout --faults 3    # 3 devices go silent mid-run
python simulate_devices.py --scenario sweep --device Room_Temperature --duration 60
python simulate_devices.py --scenario congestion --device ADC1_3V3 --rate 5000   # -> ALMOSTFULL
python simulate_devices.py --subsystem Safety,ADC -v        # one/two subsystems, list their limits
python simulate_devices.py --channels 64                    # full 64-channel LNA/VCO/PA/Switch arrays
```

Flags: `--target` (default `192.168.2.100`, the FPGA RX chip — same as
`test_dataconcentrator.py`; use `127.0.0.1` to feed a local metric server with **no FPGA in the
path**, in which case there is no RX LED activity and no interlock),
`--duration` (0 = until Ctrl+C), `--faults` (devices to fault/silence),
`--subsystem` / `--device` (glob) / `--priority` filters, `--channels` (instances per device type,
default 8, `0` = all 64), `--max-interval` (clamps the CSV's slow 60 s parameters so dashboards
fill quickly; `0` = honour the CSV), `--base-port`, `--catalog` (default
`MetricPacketServer/slow_control_catalog.json`; pass `../MetricPacketServer/device_catalog.json`
to drive the FPGA BRAM devices PSU/COIL/FAN speed instead).

The 64-channel arrays have no limits in the CSV, so they always read *ok* — `warn`/`trip` only
move devices that actually have a band. The script prints how many are in that situation.

> **Hardware note:** `trip`, `sweep` and critical `fault`s cross the FPGA thresholds and will
> assert the **GLOBAL interlock** on the real board — clear it with **SW3** on the GateMate EVB
> afterwards. The FPGA threshold BRAM (`threshold_tables_pkg.vhd`) is generated from the same
> CSV, so it enforces the same `Critical_Low/High` the dashboards display. The ten
> DeviceTypeIDs whose `Critical_*` columns are still blank (LNA, VCO V1/Temp, PA, Switch) are
> left at the **fail-safe zero** entry, so on hardware *every* reading from them trips the
> interlock — the script prints this warning whenever `--target` is not localhost.

> **Regenerating catalog + thresholds:** after editing `Slow_control_protocol_example.csv`:
> ```bash
> python MetricPacketServer/build_slow_control_catalog.py          # -> slow_control_catalog.json
> python MetricPacketServer/build_slow_control_catalog.py --vhdl   # -> paste into threshold_tables_pkg.vhd
> docker compose up -d --build metric-packet-server
> ```

> **Host IP:** the three receiver scripts (`rtt_test_script.py`,
> `measure_time_until_alert.py`, `random_port_test.py`) no longer hardcode the bind
> address. They call `resolve_host_ip()` (in `net_utils.py`), which auto-detects the
> host's address on the `192.168.2.0/24` FPGA subnet — so a reboot that hasn't yet
> re-applied `192.168.2.106` gives a clear, actionable error instead of an
> `OSError: [Errno 99] Cannot assign requested address` crash. Override with
> `SCIS_HOST_IP=192.168.2.106 python <script>.py` if detection picks the wrong one.

> **Port conflict:** `rtt_test_script.py`, `measure_time_until_alert.py`, and
> `random_port_test.py` bind to `<host-ip>:9217…`, which collides with the Metric
> Packet Server's `0.0.0.0:9217` bind. **Stop the metric server** (`docker compose stop
> metric-packet-server`) before running those three. `test_dataconcentrator.py`
> (sender-only) and `test_can_interlock.py` (HTTP observer) can run while it is up.

## Running the tests

Disable coalescing timer effects:
```bash
ethtool -C eth0 rx-usecs 0
```
Running a test pinned to a single CPU core with real-time priority (replace with the
script you want to run):
```bash
sudo taskset -c 4 chrt -f 80 python rtt_test_script.py
```

