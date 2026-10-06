# tether-vpn

Send **all** of a Linux computer's traffic through the SOCKS5 proxy that an
Android phone shares with TetherFuseNet, over USB or Wi-Fi Direct.

Apps on the computer don't need any proxy settings. tether-vpn creates a
virtual network card, routes the internet into it, and
[tun2socks](https://github.com/xjasonlyu/tun2socks) forwards every connection
(TCP and UDP) to the phone's proxy. It starts on its own when the phone
connects and puts everything back when the phone goes away.

It works alongside:

- **Tailscale**: tailnet addresses and advertised subnets (e.g. your home LAN)
  still go through Tailscale, and Tailscale's own traffic goes through the
  phone.
- **Full-tunnel VPNs** such as WireGuard in NetworkManager or `wg-quick`: the VPN
  takes over the internet, and its encrypted packets go through the phone.
- **Docker** and the local network.

```
apps ──► [WireGuard (optional)] ──► tether0 ──► tun2socks ──► phone's SOCKS5 proxy ──► internet
           Tailscale subnets ──► tailscale0 ──┘ (Tailscale's packets also use tether0)
```

## Requirements

- Linux with **NetworkManager** and **systemd-resolved** (developed on Fedora 43)
- **tun2socks** by xjasonlyu (the old `go-tun2socks` by eycorsican, as packaged
  by some distros, also works). Install with either:
  - `go install github.com/xjasonlyu/tun2socks/v2@latest` (the installer copies
    it from `~/go/bin`), or
  - a release binary from <https://github.com/xjasonlyu/tun2socks/releases>
    saved as `/usr/local/bin/tun2socks`
- An Android phone running TetherFuseNet

## Install

```bash
git clone <this repo> && cd tether-vpn
sudo ./install.sh
```

This installs:

| File in repo | Installed to | Purpose |
|---|---|---|
| `bin/tether-vpn` | `/usr/local/sbin/tether-vpn` | The script that does the work |
| `config/tether-vpn.conf` | `/etc/tether-vpn.conf` | Settings (never overwritten on reinstall) |
| `systemd/tether-vpn.service` | `/etc/systemd/system/` | Runs the tunnel in the background |
| `networkmanager/90-tether-vpn` | `/etc/NetworkManager/dispatcher.d/` | Starts/stops the service when the phone connects/disconnects |
| `networkmanager/90-tether-vpn-unmanaged.conf` | `/etc/NetworkManager/conf.d/` | Stops NetworkManager from touching the TUN device |

To update, `git pull` and run `sudo ./install.sh && sudo systemctl restart tether-vpn`.
To remove everything (except your config), run `sudo ./install.sh uninstall`.

## Phone setup

**USB (faster, recommended)**

1. Plug the phone in and turn on Android's **USB tethering**.
2. In TetherFuseNet's expert settings, set the broadcast type to **USB Tethering**,
   then start it.

**Wi-Fi Direct**

1. Start TetherFuseNet with its normal Wi-Fi Direct broadcast.
2. Connect the computer to its network (its name starts with `DIRECT-`).

In both cases tether-vpn waits until the proxy answers before taking over
routing. Plain USB tethering without TetherFuseNet is left alone.

## Usage

There is nothing to do day to day. The NetworkManager hook starts the service
when a matching link comes up. To manage it by hand:

```bash
tether-vpn status            # same as: systemctl status tether-vpn
sudo tether-vpn start | stop | restart
tether-vpn uplinks           # links that could reach the phone right now
sudo tether-vpn cleanup      # undo every change (safe to run any time)
journalctl -u tether-vpn -f  # live log
```

`tools/latency-test.sh [PHONE_IP:PORT]` measures how much latency the tunnel adds.

## Configuration

Edit `/etc/tether-vpn.conf` and then run `sudo tether-vpn restart`.

| Setting | Default | Meaning |
|---|---|---|
| `SSIDS` | `("DIRECT-*")` | Wi-Fi names (shell globs) that mean "the phone" |
| `USB_TETHER` | `yes` | Also use the phone's USB tethering link |
| `USB_DRIVERS` | `(rndis_host cdc_ncm)` | Kernel drivers that identify a USB-tethered phone |
| `PROXY_HOST` | `auto` | Proxy IP; `auto` uses the link's gateway (the phone) |
| `PROXY_PORT` | `8228` | TetherFuseNet's proxy port |
| `DNS_SERVERS` | Cloudflare, Quad9 | DNS-over-TLS servers used while the tunnel is up (`IP#hostname`) |
| `TUN_DEV`, `TUN_ADDR`, `TUN_GW` | `tether0`, `198.18.0.1`, `198.18.0.2` | The virtual card; pick a range nothing else uses |
| `TUN2SOCKS` | auto-detected | Path to the tun2socks binary |

## How it works

In short: a `default dev tether0 metric 0` route wins over NetworkManager's
default route without changing it. The phone's own subnet stays more specific,
so tun2socks can still reach the proxy. IPv6 is switched off on the uplink so
nothing leaks around the tunnel, and DNS goes over TLS through the tunnel.

See [docs/how-it-works.md](docs/how-it-works.md) for the details, including
why this works with Tailscale and full-tunnel VPNs.

## Troubleshooting

**The service never comes up.** Run `journalctl -u tether-vpn -e`. A line like
"waiting for the proxy (port 8228)" means the computer can see the phone but
the proxy isn't answering. Check that TetherFuseNet is running, the port
matches, and (for USB) its broadcast type is set to *USB Tethering*. After
repeated failures systemd stops retrying; run `sudo systemctl reset-failed tether-vpn`.

**Names don't resolve.** DNS uses DNS-over-TLS on TCP port 853 through the
proxy. If that port is blocked, change `DNS_SERVERS` in the config.

**A VPN connects but small requests work while big downloads or pages hang.**
The VPN's packets are too big for the path through the phone. Lower the VPN's
MTU, e.g. `nmcli con mod <vpn> wireguard.mtu 1280`.

**A full-tunnel VPN connects, but traffic doesn't go through it.** You are
probably on a version older than this fix (it used `0.0.0.0/1` +
`128.0.0.0/1` routes). Reinstall and restart the service.

## Repository layout

```
bin/tether-vpn                  main script (start/stop/run/cleanup/uplinks)
config/tether-vpn.conf          default settings, copied to /etc on first install
systemd/tether-vpn.service      systemd unit (started by the NetworkManager hook, not at boot)
networkmanager/                 dispatcher hook + "leave tether0 alone" config
tools/latency-test.sh           latency benchmark
docs/how-it-works.md            routing, DNS and compatibility details
install.sh                      install / uninstall
LICENSE                         MIT
```

## License

[MIT](LICENSE)
