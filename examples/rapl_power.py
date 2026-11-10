#!/usr/bin/env python3
"""Average Intel RAPL power (W) since the previous run, as JSON: {"psys": W, "package": W}.

Run every minute by the automation in rapl_power.yaml, which publishes the
output to chromebox/power for the Chromebox MQTT device. The previous counter
readings live in /tmp, so each run reports the true average over the interval.
Counters wrap at max_energy_range_uj. On the first run after a restart it
samples for 2 s. Only the HA core container can read /sys/class/powercap
(Docker masks it for add-ons).
"""
import glob
import json
import sys
import time

DOMAINS = {"psys": "psys", "package": "package-0"}
STATE_FILE = "/tmp/rapl_power.json"


def read_int(path):
    with open(path) as f:
        return int(f.read())


def domain_paths():
    found = {}
    for d in glob.glob("/sys/class/powercap/intel-rapl:*"):
        try:
            with open(d + "/name") as f:
                name = f.read().strip()
        except OSError:
            continue
        for key, want in DOMAINS.items():
            if name == want:
                found[key] = d
    missing = set(DOMAINS) - set(found)
    if missing:
        sys.exit(f"RAPL domains not found: {sorted(missing)}")
    return found


def snapshot(paths):
    return {"t": time.monotonic(), **{k: read_int(d + "/energy_uj") for k, d in paths.items()}}


def main():
    paths = domain_paths()
    try:
        with open(STATE_FILE) as f:
            prev = json.load(f)
        if set(DOMAINS) - set(prev):
            raise ValueError
    except (OSError, ValueError):
        prev = snapshot(paths)
        time.sleep(2)

    now = snapshot(paths)
    with open(STATE_FILE, "w") as f:
        json.dump(now, f)

    dt = now["t"] - prev["t"]
    if dt <= 0:
        sys.exit("non-positive interval")
    out = {}
    for key, d in paths.items():
        delta = now[key] - prev[key]
        if delta < 0:
            delta += read_int(d + "/max_energy_range_uj")
        out[key] = round(delta / dt / 1e6, 2)
    print(json.dumps(out))


if __name__ == "__main__":
    main()
