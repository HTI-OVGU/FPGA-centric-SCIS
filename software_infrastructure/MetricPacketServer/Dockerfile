# Metric Packet Server — receives UDP metric packets/alerts from the FPGA (W5500)
# on UDP ports 9217-9224 and exposes them to Prometheus on :8001 (/metrics).
# Run with host networking so the UDP listeners and the :8001 scrape endpoint
# bind directly on the host (Prometheus runs on the host network and scrapes
# localhost:8001).
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY metric_packet_server.py .
COPY device_catalog.json .
COPY slow_control_catalog.json .

# Informational only (host networking ignores published ports):
#   TCP  8001        Prometheus scrape endpoint (/metrics)
#   UDP  9217-9224   metric packets / alerts from the FPGA
EXPOSE 8001/tcp

# -u: unbuffered stdout/stderr so logs show up in `docker logs`
CMD ["python", "-u", "metric_packet_server.py"]
