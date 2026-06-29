# SteamOS CEC + Bluetooth Wake

Installs CEC TV power/input control and Bluetooth wake-from-suspend for a DIY SteamOS PC. This is based on the Reddit guide here: [Guide: CEC + Bluetooth wake on a DIY SteamOS PC](https://www.reddit.com/r/SteamOS/comments/1uiuk4m/guide_cec_bluetooth_wake_on_a_diy_steamos_pc/).

The CEC setup is specifically for the UGREEN 8K@60Hz Active DisplayPort to HDMI Adapter, model 85996. Update that adapter's firmware first, make sure TV-side CEC is enabled, and do a full reboot back into Game Mode before testing. Firmware instructions: https://m.media-amazon.com/images/I/81ks1w+SzEL.pdf

If you installed an older version of this script, re-run `--install`. The correct CEC integer for `3.0.0.0` is `12288`, not `196608`.

Install:

```sh
curl -fsSL https://raw.githubusercontent.com/xXJSONDeruloXx/steamos-cec-bt-wake/main/steamos-cec-bt-wake.sh | sudo bash -s -- --install
```

Verify:

```sh
curl -fsSL https://raw.githubusercontent.com/xXJSONDeruloXx/steamos-cec-bt-wake/main/steamos-cec-bt-wake.sh | sudo bash -s -- --verify
```

Uninstall:

```sh
curl -fsSL https://raw.githubusercontent.com/xXJSONDeruloXx/steamos-cec-bt-wake/main/steamos-cec-bt-wake.sh | sudo bash -s -- --uninstall
```

Supported environment overrides:

- `CEC_DEVICE=/dev/cec0`
- `CEC_PHYSICAL_ADDRESS=3.0.0.0`
- `DESKTOP_USER=deck`
- `BT_VENDOR=0e8d`
- `BT_PRODUCT=0616`
