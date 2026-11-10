# Power sensors (optional)

`rapl_power.py` + `rapl_power.yaml` add **Platform power** (RAPL psys, the whole SoC
platform) and **CPU package power** to the Chromebox MQTT device, once a minute, as true
averages over the interval. Intel CPUs only. Steps are at the top of `rapl_power.yaml`.

If you already use packages, the YAML file can go in `/config/packages/` as is.
