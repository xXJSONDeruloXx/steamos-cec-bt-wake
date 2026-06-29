# SteamOS CEC + Bluetooth Wake

This script installs, verifies, and removes SteamOS CEC TV wake plus Bluetooth wake support for a DIY SteamOS PC. It is based on the guide shared in this Reddit post: [Guide: CEC + Bluetooth wake on a DIY SteamOS PC](https://www.reddit.com/r/SteamOS/comments/1uiuk4m/guide_cec_bluetooth_wake_on_a_diy_steamos_pc/).

The CEC setup in that guide is specifically for the UGREEN 8K@60Hz Active DisplayPort to HDMI Adapter, model 85996, which is a DP 1.4 to HDMI 2.1 adapter with CEC passthrough. 

Additionally, see instructions on how to update the UGREEN DP Addaptor's firmware here: https://m.media-amazon.com/images/I/81ks1w+SzEL.pdf

Firmware Updator (windows exe)
https://www.mediafire.com/file/ibuw3ezvcefcpwn/85564&85996-CH7

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
