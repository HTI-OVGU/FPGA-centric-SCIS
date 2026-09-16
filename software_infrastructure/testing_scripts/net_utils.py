"""Shared network helpers for the SCIS testing scripts.

The receiver scripts (rtt_test_script, random_port_test, measure_time_until_alert)
must bind to the host's address on the FPGA subnet -- that is the IP the FPGA TX
chip returns telemetry to. Hardcoding it (``sock.bind(("192.168.2.106", ...))``)
means a cryptic ``OSError: [Errno 99] Cannot assign requested address`` whenever
that address is not on any interface *yet* -- e.g. right after a reboot, before
NetworkManager has re-applied the static 192.168.2.106/24 config, or when the
FPGA link was down at boot so the connection never activated.

``resolve_host_ip()`` picks the address the kernel would actually use to reach the
FPGA and, failing that, scans the local interfaces for one on the FPGA subnet, so
the scripts adapt instead of crashing -- and print an actionable message if the
subnet really is missing.
"""

import os
import socket
import subprocess
import sys

FPGA_SUBNET_PREFIX = "192.168.2."


def _kernel_source_ip(target_ip):
    """Source IP the kernel would use to reach target_ip (sends no packets)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((target_ip, 9))  # UDP connect only sets the route; no traffic
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


def _local_ipv4_addrs():
    """All IPv4 addresses currently configured on local interfaces."""
    try:
        out = subprocess.run(
            ["ip", "-4", "-o", "addr", "show"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return []
    addrs = []
    for line in out.splitlines():
        # "2: enp0s31f6    inet 192.168.2.106/24 brd ..."
        if " inet " in line:
            addrs.append(line.split(" inet ", 1)[1].split("/", 1)[0].strip())
    return addrs


def resolve_host_ip(target_ip, subnet_prefix=FPGA_SUBNET_PREFIX):
    """Return the local IP to bind to for talking to the FPGA at target_ip.

    Preference order:
      1. $SCIS_HOST_IP (manual override).
      2. The kernel's chosen source IP for target_ip, if it is on the FPGA subnet.
      3. Any local address on the FPGA subnet.

    Exits with an actionable message if nothing on the subnet is available.
    """
    override = os.environ.get("SCIS_HOST_IP")
    if override:
        return override

    candidate = _kernel_source_ip(target_ip)
    if candidate and candidate.startswith(subnet_prefix):
        return candidate

    for ip in _local_ipv4_addrs():
        if ip.startswith(subnet_prefix):
            return ip

    sys.exit(
        f"ERROR: no local IP on the {subnet_prefix}0/24 (FPGA) subnet was found.\n"
        f"The host needs its static address (e.g. 192.168.2.106) on the interface\n"
        f"wired to the FPGA before this test can send or receive telemetry.\n"
        f"  * check the link:    ip -4 addr show\n"
        f"  * re-apply the IP:   nmcli con up 'Wired connection 3'\n"
        f"  * or override it:    SCIS_HOST_IP=192.168.2.106 python <script>.py"
    )
