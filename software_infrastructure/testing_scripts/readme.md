Run tests with

ethtool -C eth0 rx-usecs 0
sudo taskset -c 4 chrt -f 80 python looptest_metric_packet.py

such that only one CPU core is assigned to run the Python script