import socket
import time
import numpy as np
import matplotlib.pyplot as plt

from net_utils import resolve_host_ip

# Dual-W5500 FPGA: send the metric to the RX chip (192.168.2.100); the resulting
# telemetry is emitted by the TX chip and arrives back at the host (192.168.2.106),
# so the RTT measured here is ingest (.100) -> data_concentrator -> egress (.106).
TARGET_IP = "192.168.2.100"
TARGET_PORT = 9217

# Bind to whatever address the host actually holds on the FPGA subnet, so a
# reboot that has not (yet) re-applied 192.168.2.106 gives a clear error instead
# of an "OSError: [Errno 99] Cannot assign requested address" crash.
HOST_IP = resolve_host_ip(TARGET_IP)
print(f"Binding to host IP {HOST_IP}, sending to {TARGET_IP}:{TARGET_PORT}")

NUM_PACKETS = 8192*1

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(0.001)  # Set a timeout of 1 milliseconds

round_trip_times = []
timeouts = 0

test_data = b"V01P10000"

sock.bind((HOST_IP, TARGET_PORT))

try:
    for _ in range(NUM_PACKETS):
        send_time = time.time() * 1_000_000  # Convert to microseconds
        sock.sendto(test_data, (TARGET_IP, TARGET_PORT))
        time.sleep(0.000001)
        try:
            data, _ = sock.recvfrom(4096)
            recv_time = time.time() * 1_000_000  # Convert to microseconds
            round_trip_times.append(recv_time - send_time)
        except socket.timeout:
            timeouts += 1

except KeyboardInterrupt:
    print("\nTest interrupted")
finally:
    sock.close()

    print(f"\n=== RTT Statistics ===")
    print(f"Packets sent: {NUM_PACKETS}")
    print(f"Responses received: {len(round_trip_times)}")
    print(f"Timeouts (no response): {timeouts}")

    if not round_trip_times:
        print("No responses received — nothing to summarise or plot.")
        raise SystemExit(0)

    rtts = np.array(round_trip_times)
    print(f"Mean RTT: {np.mean(rtts):.2f} µs")
    print(f"Median RTT: {np.median(rtts):.2f} µs")
    print(f"Min RTT: {np.min(rtts):.2f} µs")
    print(f"Max RTT: {np.max(rtts):.2f} µs")
    print(f"Std Dev: {np.std(rtts):.2f} µs")

    plt.hist(round_trip_times, bins=100, density=False, alpha=1, color='blue')

    ax = plt.gca()
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)
    
    ax.set_yscale('log')
    ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda y, _: f'{(y / NUM_PACKETS) * 100:.2f}%'))
    
    xlim = ax.get_xlim()
    ylim = ax.get_ylim()

    plt.grid()
    plt.savefig("loopback_delays.svg")
    plt.show()
