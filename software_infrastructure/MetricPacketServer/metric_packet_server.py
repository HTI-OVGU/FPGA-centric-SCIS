#!/usr/bin/env python3
"""
UDP Metrics Server for Prometheus

Listens on UDP ports 9217-9224 for metric packets in the format:
- 3 bytes: Protocol version (expected: "V01")
- 2 bytes: Metric identifier
- 4 bytes: 32-bit Q22.10 metric value

Exposes metrics via HTTP endpoint for Prometheus to scrape.
"""

import socket
import struct
import threading
import logging
from prometheus_client import Gauge, start_http_server
from collections import defaultdict
import time

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

LAST_INTERLOCK = Gauge(
    'last_interlock_assertion',
    'Unix timestamp (ms precision) of the last INTERLOCK packet',
    ['port']
)

# Configuration
UDP_PORTS = range(9217, 9225)  # Ports 9217 to 9224 (inclusive)
PROMETHEUS_PORT = 8000
PACKET_SIZE = 9  # 3 + 2 + 4 bytes
PROTOCOL_VERSION = b'V01'

# Prometheus metrics - using a dictionary to dynamically create gauges
metrics = {}
metrics_lock = threading.Lock()

FRACTION_BITS = 10
SCALE = 1 << FRACTION_BITS

def from_q_format_32(qval):
    """
    Convert a signed 32-bit Q(M).10 fixed-point integer back to a float.
    """
    # Interpret as signed 32-bit integer
    if qval & 0x80000000:  # if sign bit is set
        qval = -((~qval & 0xFFFFFFFF) + 1)

    # Convert to float
    return qval / SCALE

def get_or_create_metric(identifier: str, port: int) -> Gauge:
    metric_name = f'data_concentrator_0'
    
    with metrics_lock:
        if metric_name not in metrics:
            metrics[metric_name] = Gauge(
                metric_name,
                f'UDP metric from identifier {identifier} on port {port}',
                ['identifier', 'port']
            )
            logger.info(f"Created new metric: {metric_name}")
    
    return metrics[metric_name]


def parse_packet(data: bytes) -> tuple:
    if len(data) != PACKET_SIZE:
        logger.warning(f"Invalid packet size: {len(data)} bytes (expected {PACKET_SIZE}), packet: {data}")
        return None
    
    # Parse the packet
    protocol = data[0:3]
    identifier = data[3:5]
    value_bytes = data[5:9]
    
    # Verify protocol version
    if protocol != PROTOCOL_VERSION:
        logger.warning(f"Invalid protocol version: {protocol} (expected {PROTOCOL_VERSION})")
        return None
    
    # Convert identifier to string
    identifier_str = identifier.hex()
    
    # Unpack the 32-bit integer (big-endian, signed)
    value = struct.unpack('>i', value_bytes)[0]
    f32_value = from_q_format_32(value)
    
    return protocol.decode('ascii'), identifier_str, f32_value


def udp_listener(port: int):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('0.0.0.0', port))
    
    logger.info(f"UDP listener started on port {port}")
    
    while True:
        try:
            data, addr = sock.recvfrom(1024)
            
            if data == b'INTERLOCK':
                # Get current time with millisecond precision
                # time.time() returns seconds as a float (e.g., 1672531200.123456)
                timestamp = time.time()
                LAST_INTERLOCK.labels(port=str(port)).set(timestamp)
                logger.info(f"INTERLOCK assertion received on port {port} at {timestamp}")
                continue  # Skip normal parsing

            #!/usr/bin/env python3
"""
UDP Metrics Server for Prometheus

Listens on UDP ports 9217-9224 for metric packets in the format:
- 3 bytes: Protocol version (expected: "V01")
- 2 bytes: Metric identifier
- 4 bytes: 32-bit Q22.10 metric value

Exposes metrics via HTTP endpoint for Prometheus to scrape.
"""

import socket
import struct
import threading
import logging
from prometheus_client import Gauge, start_http_server
from collections import defaultdict
import time

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

LAST_INTERLOCK = Gauge(
    'last_interlock_assertion',
    'Unix timestamp (ms precision) of the last INTERLOCK packet',
    ['port']
)

# Configuration
UDP_PORTS = range(9217, 9225)  # Ports 9217 to 9224 (inclusive)
PROMETHEUS_PORT = 8000
PACKET_SIZE = 9  # 3 + 2 + 4 bytes
PROTOCOL_VERSION = b'V01'

# Prometheus metrics - using a dictionary to dynamically create gauges
metrics = {}
metrics_lock = threading.Lock()

FRACTION_BITS = 10
SCALE = 1 << FRACTION_BITS

def from_q_format_32(qval):
    """
    Convert a signed 32-bit Q(M).10 fixed-point integer back to a float.
    """
    # Interpret as signed 32-bit integer
    if qval & 0x80000000:  # if sign bit is set
        qval = -((~qval & 0xFFFFFFFF) + 1)

    # Convert to float
    return qval / SCALE

def get_or_create_metric(identifier: str, port: int) -> Gauge:
    metric_name = f'data_concentrator_0'
    
    with metrics_lock:
        if metric_name not in metrics:
            metrics[metric_name] = Gauge(
                metric_name,
                f'UDP metric from identifier {identifier} on port {port}',
                ['identifier', 'port']
            )
            logger.info(f"Created new metric: {metric_name}")
    
    return metrics[metric_name]


def parse_packet(data: bytes) -> tuple:
    if len(data) != PACKET_SIZE:
        logger.warning(f"Invalid packet size: {len(data)} bytes (expected {PACKET_SIZE}), packet: {data}")
        return None
    
    # Parse the packet
    protocol = data[0:3]
    identifier = data[3:5]
    value_bytes = data[5:9]
    
    # Verify protocol version
    if protocol != PROTOCOL_VERSION:
        logger.warning(f"Invalid protocol version: {protocol} (expected {PROTOCOL_VERSION})")
        return None
    
    # Convert identifier to string
    identifier_str = identifier.hex()
    
    # Unpack the 32-bit integer (big-endian, signed)
    value = struct.unpack('>i', value_bytes)[0]
    f32_value = from_q_format_32(value)
    
    return protocol.decode('ascii'), identifier_str, f32_value


def udp_listener(port: int):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('0.0.0.0', port))
    
    logger.info(f"UDP listener started on port {port}")
    
    while True:
        try:
            data, addr = sock.recvfrom(1024)
            
            if data == b'INTERLOCK':
                # Get current time with millisecond precision
                # time.time() returns seconds as a float (e.g., 1672531200.123456)
                timestamp = time.time()
                LAST_INTERLOCK.labels(port=str(port)).set(timestamp)
                logger.info(f"INTERLOCK assertion received on port {port} at {timestamp}")
                continue  # Skip normal parsing
            
            if data == b'ALMOSTFULL':
                logger.info(f"ALMOST FULL, FIFO Congestion detected in Data Concentrator")
                continue

            result = parse_packet(data)
            if result:
                protocol, identifier, value = result
                logger.debug(f"Port {port}: Received metric {identifier}={value} from {addr}")
                
                metric = get_or_create_metric(identifier, port)
                metric.labels(identifier=identifier, port=str(port)).set(value)
            
        except Exception as e:
            logger.error(f"Error in UDP listener on port {port}: {e}", exc_info=True)


def main():
    logger.info("Starting UDP Metrics Server for Prometheus")
    
    # Start Prometheus HTTP server
    start_http_server(PROMETHEUS_PORT)
    logger.info(f"Prometheus metrics endpoint started on http://0.0.0.0:{PROMETHEUS_PORT}/metrics")
    
    # Start UDP listeners for each port
    threads = []
    for port in UDP_PORTS:
        thread = threading.Thread(target=udp_listener, args=(port,), daemon=True)
        thread.start()
        threads.append(thread)
        logger.info(f"Started listener thread for UDP port {port}")
    
    logger.info(f"All listeners started. Listening on ports {list(UDP_PORTS)}")
    logger.info("Press Ctrl+C to stop")
    
    try: # keepin main thread alive
        for thread in threads:
            thread.join()
    except KeyboardInterrupt:
        logger.info("Shutting down...")


if __name__ == '__main__':
    main()
            
            result = parse_packet(data)
            if result:
                protocol, identifier, value = result
                logger.debug(f"Port {port}: Received metric {identifier}={value} from {addr}")
                
                metric = get_or_create_metric(identifier, port)
                metric.labels(identifier=identifier, port=str(port)).set(value)
            
        except Exception as e:
            logger.error(f"Error in UDP listener on port {port}: {e}", exc_info=True)


def main():
    logger.info("Starting UDP Metrics Server for Prometheus")
    
    # Start Prometheus HTTP server
    start_http_server(PROMETHEUS_PORT)
    logger.info(f"Prometheus metrics endpoint started on http://0.0.0.0:{PROMETHEUS_PORT}/metrics")
    
    # Start UDP listeners for each port
    threads = []
    for port in UDP_PORTS:
        thread = threading.Thread(target=udp_listener, args=(port,), daemon=True)
        thread.start()
        threads.append(thread)
        logger.info(f"Started listener thread for UDP port {port}")
    
    logger.info(f"All listeners started. Listening on ports {list(UDP_PORTS)}")
    logger.info("Press Ctrl+C to stop")
    
    try: # keepin main thread alive
        for thread in threads:
            thread.join()
    except KeyboardInterrupt:
        logger.info("Shutting down...")


if __name__ == '__main__':
    main()
