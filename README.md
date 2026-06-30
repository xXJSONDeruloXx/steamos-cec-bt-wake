# SteamOS CEC + Bluetooth Wake

Installs CEC TV power/input control and Bluetooth wake-from-suspend for a DIY SteamOS PC. This is based on the Reddit guide here: [Guide: CEC + Bluetooth wake on a DIY SteamOS PC](https://www.reddit.com/r/SteamOS/comments/1uiuk4m/guide_cec_bluetooth_wake_on_a_diy_steamos_pc/).

The CEC setup is specifically for the UGREEN 8K@60Hz Active DisplayPort to HDMI Adapter, model 85996. Update that adapter's firmware first, make sure TV-side CEC is enabled, and do a full reboot back into Game Mode before testing. Firmware instructions: https://m.media-amazon.com/images/I/81ks1w+SzEL.pdf

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/xXJSONDeruloXx/steamos-cec-bt-wake/main/steamos-cec-bt-wake.sh | sudo bash -s -- --install
```

## Verify

```sh
curl -fsSL https://raw.githubusercontent.com/xXJSONDeruloXx/steamos-cec-bt-wake/main/steamos-cec-bt-wake.sh | sudo bash -s -- --verify
```

`--verify` inventories the current install even if the state file is missing. It checks:

- installed services and helper paths
- udev rules
- `/dev/cec*`
- `cecd` D-Bus visibility and current physical address
- detected Bluetooth HCI controller USB parents
- current USB wakeup state
- SteamOS atomic-update persistence coverage
- `/usr/lib/holo/holo-sync-var --dry-run all` when available

If a partial install was damaged by a previous update, `--verify` reports that as recoverable and tells you to re-run `--install`.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/xXJSONDeruloXx/steamos-cec-bt-wake/main/steamos-cec-bt-wake.sh | sudo bash -s -- --uninstall
```

## SteamOS atomic-update persistence

SteamOS updates can replace unmanaged files under `/etc`. This installer now writes `/etc/atomic-update.conf.d/steamos-cec-bt-wake.conf` so SteamOS preserves the project-managed `/etc` paths across atomic updates, including:

- `/etc/steamos-cec-bt-wake.conf`
- `/etc/steamos-cec-bt-wake/**`
- `/etc/systemd/system/cec-sleep.service`
- `/etc/systemd/system/cec-wake.service`
- `/etc/systemd/system/bt-wakeup.service`
- `/etc/udev/rules.d/91-bluetooth-wakeup.rules`
- `/etc/udev/rules.d/99-btusb-mediatek.rules`
- `/etc/atomic-update.conf.d/steamos-cec-bt-wake.conf`

The uninstall path removes that keep-list again.

When available, `--verify` also runs:

```sh
/usr/lib/holo/holo-sync-var --dry-run all
```

and reports whether any project files would still be discarded by the next update.

## Persistence layout

New installs prefer `/var/lib/steamos-cec-bt-wake/` for mutable project state and helper executables:

- `/var/lib/steamos-cec-bt-wake/state.conf`
- `/var/lib/steamos-cec-bt-wake/cec-control`
- `/var/lib/steamos-cec-bt-wake/enable-bluetooth-wakeup`

The systemd service units and udev rules still live under `/etc`, but they now point at the helpers in `/var/lib/steamos-cec-bt-wake/`.

## Migration and recovery

Existing installs that still use these legacy paths are supported:

- `/etc/steamos-cec-bt-wake.conf`
- `/etc/steamos-cec-bt-wake/cec-control`
- `/etc/steamos-cec-bt-wake/enable-bluetooth-wakeup`

To migrate an older install to the new persistence layout, just re-run `--install`. That refreshes the services, regenerates the helpers under `/var/lib/steamos-cec-bt-wake/`, and writes the atomic-update keep-list.

If a SteamOS update or manual cleanup left you with a partial install:

1. Run `sudo ./steamos-cec-bt-wake.sh --verify`
2. Review any reported missing files or disabled services
3. Re-run `sudo ./steamos-cec-bt-wake.sh --install`
4. Reboot back into Game Mode and test sleep/wake again

## Supported environment overrides

- `CEC_DEVICE=/dev/cec0`
- `CEC_PHYSICAL_ADDRESS=3.0.0.0`
- `DESKTOP_USER=deck`
- `BT_VENDOR=0e8d`
- `BT_PRODUCT=0616`
