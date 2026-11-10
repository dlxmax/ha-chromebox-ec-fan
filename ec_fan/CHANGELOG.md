# Changelog

## 3.0.0

- First public release.
- Detects the board from the EC (`ectool version` + CBI OEM id). Full support for the fizz
  family; other boards run only with `experimental_other_boards`.
- Temperature sensors are discovered from the EC sensor table instead of hardcoded.
- New options `experimental_other_boards` and `fan_sensor`.
- AMD CPUs: CPU temperature also read from `k10temp`.
