# Software Infrastructure

- Metric Packet Server : Python Script accepting UDP metric packets and UDP alerts; exposes Metrics to Prometheus using prometheus_client
- Prometheus (Version 3.6.0): time-series database ; folder contains config YAML
- testing scripts: contains python scripts used to evaluate data concentrator on Cologne Chip GateMate M1A1 implementation

## Grafana 

Grafana (open-source edition) 12 was setup using Docker CLI and persistent storage using the [following commands](https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/):


Creating a persistent storage for the Grafana Docker container
```bash
docker volume create grafana-storage
```

Starting Grafana Docker:

```bash
docker run -d -p 3000:3000 --name=grafana --volume grafana-storage:/var/lib/grafana grafana/grafana
```

Port 3000 is Grafana's default port.
Grafana and it's dashboard environments can be then accessed at http://localhost:3000 

Once Grafana is running, the running Prometheus instance can be added as a data source.