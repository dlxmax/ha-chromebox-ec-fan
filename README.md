# Chromebox add-ons for Home Assistant

[![Add repository to my Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fdlxmax%2Fha-chromebox-ec-fan)

## Chromebox EC Fan

Old Chromeboxes make cheap, low-power Home Assistant OS boxes, but their fan never stops.
This add-on rewrites the embedded controller's fan table so the fan stays off at idle, and
exposes the thresholds, fan speed and temperatures as an MQTT device. The table is reapplied
after every EC reset.

Tested on an **Acer Chromebox CXi3**: fan off at idle (board 41 to 42 °C); under a
10-minute full load the fan runs at its lowest step and the CPU holds 53 to 55 °C. Other **fizz** Chromeboxes (HP Chromebox G2, ASUS Chromebox 3, CTL Chromebox CBx1 and
the other Wukong models) use the same EC code and should work. Other boards can try an experimental mode. See the
[add-on documentation](ec_fan/DOCS.md).

### Install

1. Click the button above, or go to **Settings > Add-ons > Add-on Store > ⋮ > Repositories**
   and add `https://github.com/dlxmax/ha-chromebox-ec-fan`.
2. Install **Chromebox EC Fan**. It needs the Mosquitto broker add-on.
3. Start it. A device called **Chromebox** appears under the MQTT integration.

Home Assistant may show a warning about the add-on's access level: it needs `SYS_RAWIO`
to talk to the EC over the LPC bus. It has no other privileges and keeps default AppArmor.

### Optional: power sensors

[`examples/`](examples/) adds platform and CPU package power (Intel RAPL) to the same device.

## Credits

- `ectool` is the Chromium OS EC tool (BSD license, see `ec_fan/ectool.LICENSE`), as built by
  the [chrultrabook project](https://docs.chrultrabook.com/docs/installing/ectool.html).
- Fan behaviour from the Chromium OS EC source, `board/fizz/board.c`.

## License

MIT, except `ec_fan/ectool` (BSD, Chromium OS Authors).
