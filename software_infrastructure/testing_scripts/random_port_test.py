import socket
import time
import numpy as np
import threading

# Target IP and Port range
TARGET_IP = "192.168.2.100"
BASE_PORT = 9217
NUM_PORTS = 8  # 9217 to 9224 inclusive (8 ports total)

# Number of packets to send
NUM_PACKETS = (8192) * 16

# Counters
packets_sent = 0
packets_received = 0
sent_per_port = [0] * NUM_PORTS
received_per_port = [0] * NUM_PORTS

# ALMOSTFULL statistics
almostfull_count = 0
almostfull_per_port = [0] * NUM_PORTS


lock = threading.Lock()
running = True

test_data = b"V01P10000"  # Test message

sockets = []
for port_offset in range(NUM_PORTS):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("192.168.2.106", BASE_PORT + port_offset))
    sock.setblocking(False)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1024*1024)
    sockets.append(sock)


def receiver_thread():
    global packets_received, running, almostfull_count

    while running:
        for i, sock in enumerate(sockets):
            try:
                data, _ = sock.recvfrom(4096)
                with lock:
                    received_per_port[i] += 1
                    packets_received += 1

                if (BASE_PORT + i) == 9224 and b"ALMOSTFULL" in data:
                        almostfull_count += 1
                        almostfull_per_port[i] += 1

            except BlockingIOError:
                continue
            except Exception:
                continue


# Start receiver thread
receiver = threading.Thread(target=receiver_thread, daemon=True)
receiver.start()

try:
    for i in range(NUM_PACKETS):
        time.sleep(0.0001) 
        port_offset = int(np.clip(np.random.normal(loc=7, scale=1.5),0,7))
        #port_offset = i % NUM_PORTS  # for even distribution of ports
        target_port = BASE_PORT + port_offset
        
        sent = False
        retry_count = 0

        while not sent and retry_count < 1000:
            try:
                sockets[port_offset].sendto(test_data, (TARGET_IP, target_port))
                sent = True

                with lock:
                    sent_per_port[port_offset] += 1
                    packets_sent += 1

            except BlockingIOError:
                retry_count += 1
                print("has to retry")
                time.sleep(0.0000001)

        if not sent:
            print(f"Warning: Failed to send packet after retries")

        if (i + 1) % 10000 == 0:
            print(f"Progress: {i+1}/{NUM_PACKETS}")

except KeyboardInterrupt:
    print("Interrupted.")

finally:
    print("Waiting for remaining packets...")
    time.sleep(2.0)
    running = False
    receiver.join(timeout=2.0)  # Waiting for receiver thread to finish

    for sock in sockets:
        sock.close()

    print("\n=== Per-Port Statistics ===")
    for i in range(NUM_PORTS):
        port = BASE_PORT + i
        sent = sent_per_port[i]
        received = received_per_port[i]
        loss = sent - received
        loss_pct = (loss / sent) * 100 if sent > 0 else 0

        print(f"Port {port}: Sent={sent}, Received={received}, "
              f"Lost={loss} ({loss_pct:.2f}%)")

    print(f"\nTotal sent: {packets_sent}")
    print(f"Total received: {packets_received}")
    print(f"Overall loss: {(1 - packets_received/packets_sent)*100:.2f}%")
    print(f"Port 9224 ALMOSTFULL packets received: {almostfull_count}")
