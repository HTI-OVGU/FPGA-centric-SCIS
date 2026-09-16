# Software Infrastructure

- Metric Packet Server : Python Script accepting UDP metric packets and UDP alerts; exposes Metrics to Prometheus using prometheus_client
- Prometheus (Version 3.6.0): time-series database ; folder contains config YAML
- testing scripts: contains python scripts used to evaluate data concentrator on Cologne Chip GateMate M1A1 implementation

## Device names (catalogs)

Metric identifiers are the 16 bits the slow-control protocol puts on the wire:

```
| 'V01' 24 bit | DeviceTypeID 10 bit | Device No 6 bit | measurement 32 bit (Q22.10) |

identifier = (DeviceTypeID << 6) | DeviceNo      # for CAN metrics DeviceTypeID == CAN ID
```

**The server publishes CSV parameters and nothing else.** A packet whose identifier is not in
the catalog is counted in `dc_unknown_identifier_packets_total` and dropped — it never becomes
an unnamed `device_<id>` series, because such a series is dashboard noise that cannot be
classified against any limits. Every published series is labelled with its CSV
**`Parameter_Name`**.

[`MetricPacketServer/slow_control_catalog.json`](MetricPacketServer/slow_control_catalog.json) —
726 parameters **generated** from
[`Slow_control_protocol_example.csv`](Slow_control_protocol_example.csv), the maintained
slow-control parameter list:

| DeviceTypeID | Device No | Subsystem | Parameters |
|--------------|-----------|-----------|------------|
| `0` | 0–1 | Safety | `Emergency_Stop`, `SC_online` |
| `1`, `2` | 0 | Environment | `Room_Temperature`, `Room_Humidity` |
| `10` | 0 | DAQ Power Supply 1 | `Main_Voltage` |
| `100`–`102` | 0–63 | PreAmp / LNA | `LNAnn_V1`, `LNAnn_I1`, `LNAnn_Temp` |
| `200`–`202` | 0–63 | Mixer / VCO | `VCOnn_V1`, `VCOnn_Vtune`, `VCOnn_Temp` |
| `300`–`302` | 0–63 | PA | `PAnn_V1`, `PAnn_I1`, `PAnn_Temp` |
| `400`, `401` | 0–63 | Switch | `SWnn_I(Vctrl1)`, `SWnn_I(Vctrl2)` |
| `900`–`903` | 0–3 | ADC / DAC | board `3V3` rails and `FPGA_Temp` |
| `1023` | 0 | Slow Control | `SC_FPGA_V_Core` |

Array parameters follow the convention the CSV states explicitly for the ADC/DAC boards
(`ADC1..4_3V3` = type 900, Device No 0–3): **the channel goes into Device No, and each
parameter of a group gets its own DeviceTypeID**, counting up from the CSV's base — so the
CSV's `100+[63]` becomes types 100/101/102 with channels 0–63 in Device No.

Regenerate after editing the CSV (the metric server picks it up on rebuild):

```bash
python MetricPacketServer/build_slow_control_catalog.py
docker compose up -d --build metric-packet-server
```

### The FPGA interlock limits come from the same CSV

`hardware/hdl/data_concentrator/threshold_tables_pkg.vhd` holds the compile-time threshold BRAM. Its
address is **`metric_id(15 downto 6)`, i.e. the DeviceTypeID alone** — the Device№ is not part
of the address, so all 64 channels of a type (and all 4 ADC/DAC boards) share one
`{lower, upper}` pair. That is exactly why the CSV's array parameters map to *one
DeviceTypeID per parameter* with the channel in Device№.

The entries are the CSV's **`Critical_Low` / `Critical_High`** in Q22.10, regenerated with:

```bash
python MetricPacketServer/build_slow_control_catalog.py --vhdl                 # channel 0 (UDP)
python MetricPacketServer/build_slow_control_catalog.py --vhdl-transfer=CAN    # channel 1 (CAN)
```

So the FPGA interlock and the dashboards enforce and display the same numbers. Two rules the
generator applies:

- **Booleans** (`Emergency_Stop`, `SC_online`) get `lower = upper = 1.0`, so the interlock
  fires the moment the signal drops (the comparison is `value < lower or value > upper`).
- **Blank `Critical_*`** → the `Warning_*` band is used if there is one (`VCO_Vtune`: 0…1 V);
  if there is none either, the entry is **left commented out**, so the fail-safe zero default
  applies. Ten DeviceTypeIDs are in that state today — the LNA (100–102), VCO V1/Temp (200,
  202), PA (300–302) and Switch (400, 401) arrays. On hardware **every reading from them
  asserts the interlock** until real limits are entered in the CSV. Each has a commented-out
  ±20 % -of-nominal placeholder in the VHDL as a starting point — a placeholder, not an
  engineering limit.

### Exposed metrics

| Metric | Meaning |
|--------|---------|
| `data_concentrator_0{identifier,name,unit,subsystem}` | latest reading, from whichever transport carried it last (a CSV `Transfer=CAN` parameter injected over UDP as well shares this one series) |
| `dc_device_severity{…,priority,interlock}` | **0 = ok, 1 = warning, 2 = critical**, evaluated at ingest against the catalog limits |
| `dc_device_last_seen_timestamp_seconds` | when the device last reported (drives the "silent" tile) |
| `dc_device_upper_threshold` / `dc_device_lower_threshold` | `Critical_High` / `Critical_Low` — the interlock limits |
| `dc_device_warn_high` / `dc_device_warn_low` | `Warning_High` / `Warning_Low` |
| `dc_device_nominal` | `Nominal_Value` |
| `last_interlock_assertion{port}` | timestamp of the last `INTERLOCK` packet |
| `dc_metric_packets_total`, `dc_invalid_packets_total`, `dc_almostfull_total`, `dc_interlock_total` | per-port counters |
| `dc_unknown_identifier_packets_total{port}` | valid V01 packets whose identifier is not a CSV parameter (dropped, not published) |

Booleans (`Emergency_Stop`, `SC_online`) are nominal-1 signals: anything below 0.5 is critical.

To also publish the pre-CSV bench devices (PSU/COIL/FAN speed/system load from
[`device_catalog.json`](MetricPacketServer/device_catalog.json)), append that path to
`CATALOG_PATHS` in `metric_packet_server.py`.

## Running the stack with Docker Compose

All three services (Metric Packet Server, Prometheus, Grafana) are described in
[`docker-compose.yml`](docker-compose.yml). The Metric Packet Server and Prometheus run
with **host networking** — the server's UDP listeners (ports 9217–9224) and its `:8001`
scrape endpoint must share the host network namespace, and Prometheus scrapes
`localhost:8001`. Grafana stays on the default bridge and publishes `3300:3000`; its
Prometheus data source URL is `http://172.17.0.1:9090` (the host gateway).

```bash
cd software_infrastructure

# First-time only: create the persistent volumes
docker volume create prometheus-data
docker volume create grafana-storage

# Build the Metric Packet Server image and start everything
docker compose up -d --build

# …or start just the Metric Packet Server (leaves Prometheus/Grafana untouched)
docker compose up -d --build metric-packet-server
```

Verify:

```bash
curl -s localhost:8001/metrics | head            # server is exposing metrics
curl -s localhost:9090/api/v1/targets | grep -o '"health":"[^"]*"'   # -> "up"
curl -s localhost:3300/api/health                # Grafana
```

### Host network (second Ethernet)

The FPGA uses **two W5500 Ethernet chips** on the `192.168.2.0/24` network (FPGA-side
gateway `192.168.2.1`, mask `255.255.255.0`):

| W5500 chip | IP | Role |
|------------|----|------|
| RX (`receive_first`) | **`192.168.2.100`** | **ingests** metric/command UDP packets sent *to* the FPGA (host → `.100`, ports 9217–9224) |
| TX (`send_first`)    | **`192.168.2.101`** | **emits** telemetry/alert UDP packets *from* the FPGA to the host at `192.168.2.106` |

So the host **sends** test/metric traffic to `192.168.2.100` and **receives** telemetry
at `192.168.2.106` (the testing scripts in `testing_scripts/` are configured this way).
The host's second Ethernet NIC must carry a **static** `192.168.2.106/24` address — there
is no DHCP server on the FPGA link, so leaving the interface on `auto`/DHCP keeps it
disconnected. Configure it (no default route, so it can't hijack the primary uplink):

```bash
sudo nmcli connection modify "Wired connection 3" \
    ipv4.method manual ipv4.addresses 192.168.2.106/24 \
    ipv4.gateway "" ipv4.never-default yes
sudo nmcli connection up "Wired connection 3"
```

(Replace `"Wired connection 3"` / the interface name to match your machine —
`nmcli device status` lists them.)

## Prometheus

Prometheus 3.6.0 is run using the config found in `/software_infrastructure/Prometheus/prometheus.yml`.
Under Docker Compose it is started for you; to run the binary standalone:
```bash
./prometheus --config.file=prometheus.yml
```

## Grafana

Grafana (open-source edition) is deployed via Docker Compose (see above) and published on
**`http://localhost:3300`** (the container's internal port 3000 is mapped to 3300 on the host).
Persistent state lives in the `grafana-storage` Docker volume.

The Prometheus data source **and** the SCIS dashboard are **auto-provisioned** from files in
[`Grafana/`](Grafana/) — no manual setup is required:

- `Grafana/provisioning/datasources/datasource.yml` — adds Prometheus at `http://172.17.0.1:9090`
  (the Docker host gateway) as the default data source.
- `Grafana/provisioning/dashboards/provider.yml` + `Grafana/dashboards/*.json` —
  loads two dashboards on startup:
  - **SCIS Overview** (`scis-overview.json`) — the operator view, alarm-first and deliberately
    quiet while everything is healthy:
    1. a KPI row — devices *reporting*, devices *silent > 60 s*, *warnings*, *criticals*
       (red background when non-zero), and *time since the last INTERLOCK*;
    2. **Active alarms** — one row per device outside its limits, worst first, with its value,
       subsystem, priority and the `Interlock_Action` the protocol assigns it. Empty when all
       devices are inside their limits;
    3. **Subsystem status** — OK / WARNING / CRITICAL per subsystem (label *and* colour, so it
       is readable without colour vision);
    4. one time series for the subsystem picked in the `Subsystem` / `Device` variables at the
       top, one line per `Parameter_Name`. Limits are deliberately not drawn — a constant line
       is clutter, and a breach already surfaces in Active alarms.

    Severity comes straight from the `dc_device_severity` gauge, so the panels need no PromQL
    joins and adding a parameter to the CSV is enough to make it appear.
  - **SCIS Admin / Diagnostics** (`scis-admin.json`) — server health/uptime, per-port packet
    throughput, ALMOSTFULL congestion, INTERLOCK/invalid-packet rates, and a device-status table.

Populate it without hardware from `testing_scripts/`:

```bash
python testing_scripts/simulate_devices.py --scenario fault --faults 5
```

`docker compose up -d --build` mounts these into the container. After changing any provisioning
file, apply it live with `docker compose up -d grafana` (recreates the container so it re-reads
the provisioning). Open the dashboard at `http://localhost:3300` (default login `admin`/`admin`).