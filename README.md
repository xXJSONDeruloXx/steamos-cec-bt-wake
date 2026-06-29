# SteamOS CEC + Bluetooth Wake

This script installs, verifies, and removes SteamOS CEC TV wake plus Bluetooth wake support for a DIY SteamOS PC. It is based on the guide shared in this Reddit post: [Guide: CEC + Bluetooth wake on a DIY SteamOS PC](https://www.reddit.com/r/SteamOS/comments/1uiuk4m/guide_cec_bluetooth_wake_on_a_diy_steamos_pc/).

The CEC setup in that guide is specifically for the UGREEN 8K@60Hz Active DisplayPort to HDMI Adapter, model 85996, which is a DP 1.4 to HDMI 2.1 adapter with CEC passthrough. Standard HDMI ports on graphics cards do not provide the same CEC behavior.

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
