import socket
import struct
import random
import time
import threading

TARGET_IP = "192.168.2.100"
PROTOCOL_CODE = b"V01"  # HEX 56, 30, 31

def float_to_q22_10(value):
    # Q22.10 calculation: value * 2^10
    return int(round(value * (1 << 10)))

def device_worker(port, device_id, mean, std_dev, interval):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    
    print(f"[Started] Device {device_id} on Port {port} (Interval: {interval}s)")

    while True:
        # 1. Generate Gaussian value
        raw_float = random.gauss(mean, std_dev)
        q_value = float_to_q22_10(raw_float)

        # 2. Pack the 9-byte payload
        # ! = Network (Big-Endian) | 3s = "V01" | H = Unsigned Short (ID) | i = Signed Int (Q22.10)
        try:
            payload = struct.pack('!3sH i', PROTOCOL_CODE, device_id, q_value)
            
            # 3. Send
            sock.sendto(payload, (TARGET_IP, port))
            
        except Exception as e:
            print(f"Error on Port {port}: {e}")

        # 4. Wait for the next transmission
        time.sleep(interval)

# --- Configuration List ---
# Format: (Port, Device ID, Mean, Std Dev, Interval in Seconds)
DEVICES = [
    (9217, 101, 24.0, 0.5, 1.0),  # Port 9217 sends every 1 second
    (9218, 102, 400.0, 2.1, 0.5),  # Port 9218 sends every 0.5 seconds
    (9219, 103, 12.4, 0.1, 2.0),
    (9220, 104, 50.0, 10.0, 0.2),
    (9221, 105, -3.0, 1.0, 1.0),
    (9222, 106, 50.0, 5.0, 3.0),
    (9223, 107, 10.2, 0.2, 0.8),
    (9224, 108, -270.0, 0.5, 1.5),
]

if __name__ == "__main__":
    print(f"Initializing transmission to {TARGET_IP}...")
    
    threads = []
    for config in DEVICES:
        t = threading.Thread(target=device_worker, args=config, daemon=True)
        t.start()
        threads.append(t)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\nSimulation stopped by user.")