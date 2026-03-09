Tests were conducted using Python 3.13 on a host-computer running Fedora 43.

Installing all packages/libraries:
```bash
pip install -r requirements.txt
```

Disable coalescing timer effects:
```bash
ethtool -C eth0 rx-usecs 0
```
Running the tests such that only one CPU core is assigned to run the Python script and with real-time priority
```bash
sudo taskset -c 4 chrt -f 80 python main.py
```

