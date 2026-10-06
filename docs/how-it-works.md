# How tether-vpn works

## The pieces

1. **NetworkManager dispatcher hook** (`networkmanager/90-tether-vpn`) runs on
   every link change. When a Wi-Fi network whose name matches `SSIDS` comes up,
   or an ethernet card using a USB-tethering driver (`rndis_host`, `cdc_ncm`),
   it starts `tether-vpn.service`. When that link goes down, it stops the
   service.
2. **The service** runs `tether-vpn run`, which loops:
   1. **Wait for the proxy.** It checks every possible uplink (USB first) until
      the proxy port answers on the link's gateway. It exits if no uplink is
      left.
   2. **Start the tunnel.** It creates the TUN device, starts tun2socks bound to
      the uplink (`--interface`), and sets up routes and DNS.
   3. **Watch.** Every 10 seconds it checks that tun2socks is alive, the uplink
      exists and the proxy answers. After 3 failed proxy checks in a row it
      tears down.
   4. **Tear down** (`cleanup`), then go back to step 1.
3. **`cleanup`** undoes everything it can find, using `/run/tether-vpn.state`
   to remember which uplink it changed. It is safe to run any number of times
   and also runs as the unit's `ExecStopPost`.

## Routing

While the tunnel is up, the main routing table looks like this:

```
default dev tether0 metric 0                          <- added by tether-vpn
default via <phone> dev <uplink> proto dhcp metric 100 <- NetworkManager, untouched
<phone subnet> dev <uplink> proto kernel               <- more specific; reaches the proxy
198.18.0.0/24 dev tether0 proto kernel
```

- The metric-0 default route wins over NetworkManager's (metric 100), so all
  internet traffic enters `tether0` and tun2socks forwards it to the proxy.
- The phone's subnet is more specific than a default route, so tun2socks's own
  connection to the proxy goes straight out over the uplink and doesn't loop
  back into the tunnel. tun2socks is also bound to the uplink with
  `--interface`. If the proxy is outside the uplink's subnet, a `/32` route to
  it is added.
- Stopping removes the one route, and NetworkManager's default takes over
  again. tether-vpn never edits NetworkManager's routes.

### Why a /0 route and not 0.0.0.0/1 + 128.0.0.0/1

Many VPN tools add two half-routes to beat the default route. tether-vpn
doesn't, because that breaks full-tunnel VPNs layered on top.

NetworkManager's WireGuard (and `wg-quick`) take over the internet with policy
rules rather than by replacing the default route:

```
31156: from all lookup main suppress_prefixlength 0
31157: not from all fwmark 0xcabb lookup 51899      # table 51899: default dev <wg>
```

The first rule uses the main table but ignores any route with prefix length 0
(the default route). That lets normal traffic fall through to the VPN's table,
while specific routes (LAN, phone subnet) still apply. WireGuard's own encrypted
packets carry the fwmark, skip rule 31157 and use the main table's default
route, which is `tether0`.

Half-routes are `/1`, so `suppress_prefixlength 0` doesn't ignore them. They
would match first and send everything to `tether0`, past the VPN. The VPN would
complete its handshake and look connected, but carry no traffic.

### Tailscale

Tailscale adds its own rules, which are checked before the main table and
before any VPN rule:

```
5210: from all fwmark 0x80000/0xff0000 lookup main   # Tailscale's own packets
5270: from all lookup 52                             # tailnet IPs + advertised subnets
```

- Table 52 only has tailnet addresses and subnet routes (e.g. `192.168.1.0/24`),
  so those keep going to `tailscale0` whether or not another VPN is up.
- Tailscale's encrypted UDP is marked `0x80000` and uses the main table, so it
  goes through `tether0` and the phone. This works because xjasonlyu's
  tun2socks forwards UDP over SOCKS5 `UDP ASSOCIATE`, so Tailscale can usually
  still make direct connections. The occasional `symmetric NAT ... drop packet`
  warning in the log is from Tailscale's STUN probes and is harmless.
- Tailscale exit nodes are a different case: they replace the default route
  through table 52 and haven't been tested with this setup.

## DNS

The phone's DNS server usually can't be reached when its proxy is the only
way out, so while the tunnel is up:

- `tether0` gets the `DNS_SERVERS` with DNS-over-TLS enforced. DNS-over-TLS
  runs over TCP, which works through any SOCKS5 proxy.
- `tether0` gets the routing domain `~.` and becomes the default DNS route, so
  it answers every name that no other link claims.
- The uplink's default DNS route is switched off. Tailscale's MagicDNS keeps
  `*.ts.net`, and a VPN's DNS settings still apply.

## IPv6

The proxy setup only covers IPv4. USB tethering can hand out IPv6 addresses,
and that traffic would skip the tunnel, so IPv6 is disabled on the uplink while
the tunnel is up and restored to its previous value afterwards.
NetworkManager logs harmless "IPv6 is disabled on this device" warnings for
the uplink during that time.

## Two tun2socks programs

There are two unrelated programs called `tun2socks`. tether-vpn detects which
one it has from its `-h` output:

| | xjasonlyu/tun2socks | eycorsican/go-tun2socks |
|---|---|---|
| Options | `--device tun://… --proxy socks5://…` | `-tunName … -proxyServer …` |
| Creates the TUN device | no (tether-vpn does) | yes |
| Recommended | **yes** | only if it's all you have |
