# Chromebox EC Fan

Turns a Chromebox running Home Assistant OS into a quiet one. The fan is run by the
Chromebox's embedded controller (EC) from a temperature table. Out of the box that table
keeps the fan spinning all the time. This add-on rewrites the table with your thresholds
and puts them on an MQTT device called **Chromebox**.

## Requirements

- A Chromebox with coreboot UEFI firmware (MrChromebox), which you need to run HAOS on it anyway.
- The Mosquitto broker add-on and the MQTT integration.

## Supported hardware

| Board | Models | Status |
|---|---|---|
| Sion | Acer Chromebox CXi3 | tested |
| Kench | HP Chromebox G2 | should work (same EC code), please report |
| Teemo | ASUS Chromebox 3 (CN65) | should work (same EC code), please report |
| Wukong | CTL Chromebox CBx1, Promethean Chromebox, SMART Chromebox G3, ViewSonic NMP660 Chromebox | should work (same EC code, different fan RPMs), please report |
| Jax | AOpen Chromebox Commercial 2, Newline Chromebox A10 | no fan, the add-on exits |
| Excelsior | Google Meet kit (Kaby Lake) | different fan stop point, experimental mode only |
| anything else | e.g. puff boards (Chromebox 4 generation) | experimental, opt-in, untested |

The fizz EC code also knows a sixth variant, Bleemo, with no known retail model. Board to
model names are from the [MrChromebox supported devices list](https://docs.mrchromebox.tech/docs/supported-devices.html).

The add-on detects the board from the EC itself (`ectool version` and the CBI OEM id), not from
the model name.

## Entities (fizz)

- **Fan starts at** / **Fan stops at** (`number`, in the device's configuration section): the
  Board temperature 1 readings where the fan starts and stops, 3 to 18 °C apart. Default 46 / 43.
  Bad combinations are rejected and the entity snaps back.
- **Fan speed** (rpm).
- **Board temperature 1** (EC sensor 0, TMP431 internal, drives the fan, holds the EC 80 °C
  warning and 81 °C shutdown) and **Board temperature 2** (TMP431 remote).
- **CPU temperature** (the CPU's own sensor, display only: the EC cannot read it).

Full speed follows from start and stop, because the EC has only two thresholds per sensor;
the add-on log shows it on every change.

### How the fizz numbers work

The EC turns temperature into demand: `% = (t - fan_off) / (fan_max - fan_off)`. Fizz boards
then map demand to RPM through a step table with hysteresis
(`board/fizz/board.c`, `fan_step_1_1`): the fan starts at 36 % and stops only near 0 %.
So `fan_off` is set to your stop temperature and the span is chosen so that your start
temperature is the first one to reach 36 %.

## Experimental mode (other boards)

Set `experimental_other_boards: true`. The two numbers become the raw EC values:
**Fan starts at** (`fan_off`) and **Full speed at** (`fan_max`), starting from what the EC
already has, so installing changes nothing until you edit them. Many boards replace the
linear curve with their own table, so the real start and stop points may differ from the
numbers. Temperature sensors are named after the EC's sensor names. Other sensors' fan fields
are left alone, because on other boards one of them may be the CPU.

If your board is refused, the log prints the EC thermal table; please open an issue with it.

## Options

| Option | Default | Meaning |
|---|---|---|
| `poll_interval` | 60 | Seconds between reading sensors and reapplying the table (15 to 3600) |
| `experimental_other_boards` | false | Run on boards other than fizz (see above) |
| `fan_sensor` | auto | EC sensor index that drives the fan. fizz: 0. Other boards: the first sensor with a fan table |

## Safety

- The EC keeps the table in RAM only. This add-on reapplies it every poll. If the add-on stops
  or the EC resets, the EC falls back to its factory table: the fan runs all the time. Noisy,
  never hot.
- The EC's warning, high and halt limits are never changed.
- Full speed is always kept below the EC's high limit.

## Uninstalling

Uninstalling leaves retained discovery topics under `homeassistant/+/ec_fan/`; delete the
device from the MQTT integration afterwards.

## Power sensors (optional)

Add-ons cannot read Intel RAPL, but Home Assistant core can. The repository's `examples/`
folder has a script and automation that add **Platform power** and **CPU package power** to
the same device.
