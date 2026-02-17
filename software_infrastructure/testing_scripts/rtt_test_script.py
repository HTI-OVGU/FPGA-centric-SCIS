import socket
import time
import numpy as np
import matplotlib.pyplot as plt

# Target IP and Port
TARGET_IP = "192.168.2.100"
TARGET_PORT = 9217

NUM_PACKETS = 8192*1

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(0.001)  # Set a timeout of 1 milliseconds

round_trip_times = []

test_data = b"V01P10000" 

sock.bind(("192.168.2.106", TARGET_PORT)) 

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
            print("Packet timeout")

except KeyboardInterrupt:
    print("\nTest interrupted")
finally:
    sock.close()
    
    rtts = np.array(round_trip_times)
    print(f"\n=== RTT Statistics ===")
    print(f"Total packets: {len(rtts)}")
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
