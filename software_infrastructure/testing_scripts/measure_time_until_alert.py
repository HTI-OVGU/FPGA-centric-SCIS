import socket
import time
from datetime import datetime

TARGET_IP = "192.168.2.100"
TARGET_PORT = 9217

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(5.0)  # 5 second timeout

test_data = b"V01P10000"  # Test message to send

sock.bind(("192.168.2.106", TARGET_PORT)) 

try:
    print("Sending command and waiting for INTERLOCK response...")
    
    send_time = time.time() * 1_000_000  # Convert to microseconds  
    sock.sendto(test_data, (TARGET_IP, TARGET_PORT))
    
    while True:
        try:
            data, addr = sock.recvfrom(4096) 
            
            if data == b"INTERLOCK":
                recv_time = time.time() * 1_000_000  # Convert to microseconds
                rtt = recv_time - send_time
                print(f"\n=== INTERLOCK Received ===")
                print(f"Round-trip time: {rtt:.2f} µs")
                print(f"Received from: {addr}")
                
                # Write to file
                timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                with open("rtt_log.txt", "a") as f:
                    f.write(f"{rtt:.2f} µs\n")
                print("RTT logged to rtt_log.txt")
                
                break
            
        except socket.timeout:
            print("Timeout: No response received")
            break

except KeyboardInterrupt:
    print("\nTest interrupted")
finally:
    sock.close()
