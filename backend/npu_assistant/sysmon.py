"""Cheap readings of memory and CPU pressure."""
import os


def mem_available_gb():
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) / 1048576
    return 0.0


def cpu_psi_avg10():
    try:
        with open("/proc/pressure/cpu") as f:
            for part in f.readline().split():
                if part.startswith("avg10="):
                    return float(part[6:])
    except OSError:
        pass
    return 0.0


def load_ratio():
    return os.getloadavg()[0] / (os.cpu_count() or 1)
