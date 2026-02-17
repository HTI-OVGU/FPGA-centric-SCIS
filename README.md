# FPGA-centric Slow Control Interlock System (SCIS)

This Project aims to build a Slow Control Interlock system, based on a Data Concentrator implemented on a Cologne Chip GateMate M1A1 FPGA and utilizing the W5500 Ethernet platform.

## Slow Control Architecture

The Software architecture consists of a Metric Packet Server, Prometheus and Grafana

Source Code, testing and configuration files are found in /software_infrastructure

Prometheus 3.6.0 was used an run using a config yaml found in /software_infrastructure/Prometheus:
```bash
./prometheus --config.file=prometheus.yaml
```

Grafana 12 was configured to run as a docker container with a persistent volume and with exposed HTTP port 3000.
Prometheus was added to Grafana as a data source.

## Data Concentrator

This repository contains the VHDL source files, constraints and a makefile to build the project for the CologneChip GateMate M1A1 FPGA Board. Building the project requires the OSS-CAD-Suite by YosysHQ, tested with Build 21-01-2026.

Building the data concentrator project for two W5500s connected to the PMOD pins:
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
```

Adding new devices to the Threshold Lookup Memory can be done using the threshold_address_generator.py script.


Working:
- W5500 controller (UDP) with round robin through all 8 sockets
- W5500 controller "send_first" and "receive_first" default routines
- Highest priority first readout from Priority FIFOs in Metric Packet Manager
- Implements at 40 MHz FPGA sys_clk speed
- Dual W5500, one for RX and one for TX
- Protocol Code V01 (signed Q22.10 values)
- Data concentrator with UDP packet adapter, Metric Packet Manager and first version of interlock protocol code V01 Metric Packets

ToDo/Bug:
- RX W5500 sometimes closes socket, when bombarded with UDP packets that exceed the 2KB RX Buffer

Backlog : 
- W5500 Controller for TCP packets (strips the UDP Packet Header from tdata on AXI-streams)
