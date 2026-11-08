# Laptop side, portable

One script and one binary in a folder. Nothing is installed, no package manager
is needed and nothing runs at boot. Use this on immutable distros (Bazzite,
Fedora Silverblue/Kinoite, SteamOS) or anywhere you would rather not install
sing-box system-wide. For the installed, systemd-managed setup on Arch, see
[`../README.md`](../README.md).

`proxy-singbox.sh` sends **all** of the laptop's traffic through the phone:
TCP, UDP and DNS, including apps that ignore proxy settings. Other devices that
join the laptop's hotspot (a console, a tablet, another laptop) are routed
through it too, with no setup on their side. It has been used
end to end on Bazzite with an iPhone on T-Mobile US, including Discord voice.

## Requirements

**Phone:** SocksBypass built from this fork's `main`. The NAT64, UDP and
cellular-pinning fixes it carries are what make UDP and IPv4 destinations work
through a TUN; older builds connect but fail on IPv6-only carriers.

**Laptop:**

- Linux, x86-64 or ARM64, run as root (`sudo`)
- `systemd-resolved` handling DNS (the default on Fedora-based and most current
  distros)
- `nft`, `ip` (iproute2), `bash`, and the `tun` kernel module, all present on
  any desktop distro
- A WiFi access point the phone joins. A NetworkManager hotspot is the easy one:
  it hands out `10.42.0.x` addresses. It needs no internet of its own.
- [sing-box](https://github.com/SagerNet/sing-box) **1.12 or newer**, as the
  standalone binary from its releases page. Tested with 1.14.4.

## Install (once)

Pick a folder; everything lives in it.

```sh
mkdir -p ~/phone-proxy && cd ~/phone-proxy
```

1. **sing-box.** From <https://github.com/SagerNet/sing-box/releases>, download
   `sing-box-<version>-linux-amd64.tar.gz`, or `-linux-arm64` on an ARM laptop
   (`uname -m` says which: `x86_64` is amd64). Then:

   ```sh
   tar xzf sing-box-*-linux-*.tar.gz
   mv sing-box-*/sing-box .
   ```

2. **The script.** Copy `proxy-singbox.sh` from this directory into the folder.

3. **Make both executable:**

   ```sh
   chmod +x sing-box proxy-singbox.sh
   ```

4. **Set the phone's address.** Open `proxy-singbox.sh` and edit the two lines
   at the top:

   ```sh
   PROXY_IP="10.42.0.10"     # the phone's address, as shown in the app
   PROXY_PORT="9876"
   ```

   The app shows its address once the relay is running. From the laptop,
   `ip neigh` lists it too.

The folder should now hold just `sing-box` and `proxy-singbox.sh`.

## Run

1. Start the laptop's access point and join it from the phone.
2. Start the relay in SocksBypass, and leave it in the foreground.
3. On the laptop:

   ```sh
   sudo ./proxy-singbox.sh up
   ```

   It stays in the foreground. **Ctrl+C stops it** and puts networking and DNS
   back the way they were.

Check it from a second terminal:

```sh
curl https://ifconfig.me        # should print the phone's carrier IP
```

After the first start, restart long-running apps (browsers, Discord) so they
drop connections and DNS answers from before the tunnel came up.

### Logging

```sh
sudo ./proxy-singbox.sh up info 2>&1 | tee proxy.log
```

`info` logs every connection; `debug` logs much more. The phone keeps its own
log too: `curl http://<phone-ip>:9877/` (see the main README's Diagnostics).

### Other devices on the hotspot

While the script runs, the laptop acts as their router. A device that joins
the hotspot gets its address and DNS from the hotspot as usual, and its traffic
is forwarded into the tunnel and out through the phone. Nothing needs
configuring on the device. Everyone shares the phone's cellular bandwidth and
data allowance.

The iPhone itself is the one device that is never forwarded: its traffic would
go into the tunnel and straight back to it.

### If a run was killed

If the script was killed rather than stopped with Ctrl+C (terminal closed,
`kill -9`, a crash), clean up with:

```sh
sudo ./proxy-singbox.sh down
```

## What it changes while running

Everything below is undone on exit, except where noted.

- **A TUN device, `tun0`,** with routes that send all traffic into sing-box.
  The hotspot's own subnet is excluded, so the connection to the phone does not
  loop back into the tunnel.
- **DNS.** `systemd-resolved` sends every lookup to sing-box, and other
  interfaces' DNS servers are taken out of the default route. sing-box resolves
  over TCP, through the phone, against Cloudflare (`2606:4700:4700::1111`), so
  no lookup leaves the laptop any other way. If `/etc/resolv.conf` is not the
  `systemd-resolved` stub, it is pointed there and the original restored after.
- **An nftables table, `proxy_singbox`,** that refuses to forward the
  iPhone's own traffic. Otherwise the laptop would offer the phone an internet
  connection through the tunnel, which leads straight back to the phone.
  Other hotspot devices are forwarded normally.
- **IPv4 forwarding** (`net.ipv4.ip_forward`) is switched on, so other hotspot
  devices can be routed. NetworkManager hotspots already turn it on; it is left
  on afterwards.

It also writes `proxy-singbox.json`, the generated sing-box config, next to the
script. It is regenerated on every start.

## Why the config is the way it is

Each of these fixed a real failure:

- **Real DNS, no FakeIP.** With FakeIP the phone is handed hostnames, and its
  UDP relay resolves those through the laptop's DNS, which is sing-box, which
  answers with another fake address. UDP to hostnames never worked. Resolving
  on the laptop means the phone only ever sees IP addresses.
- **DNS over TCP.** It rides the same relay path as everything else and does
  not depend on how the carrier handles UDP to port 53.
- **5-minute UDP timeout.** sing-box gives flows it recognises as STUN a
  10-second idle timeout. WebRTC voice (Discord) runs STUN and DTLS on the same
  flow, so calls were torn down mid-handshake and never connected.
- **TUN MTU 9000** (sing-box's default). It is the MTU between the kernel and
  sing-box, not on any wire. At 1400, large inbound UDP such as a DTLS
  certificate flight could not be delivered into the tunnel.
- **`ipv4_only` DNS.** Apps get IPv4 addresses, which the phone rewrites to the
  carrier's NAT64 addresses on IPv6-only networks.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `No route to 10.42.0.10` at start | Phone not on the access point, or `PROXY_IP` is wrong. |
| `sing-box not found or not executable` | Binary not in the same folder, or missing `chmod +x`. |
| `Config check failed` mentioning DNS servers | sing-box older than 1.12. |
| `curl https://1.1.1.1` works but names don't resolve | Another DNS setup on the machine is overriding `systemd-resolved`; check `resolvectl status`. |
| Everything stops at once | The phone app was suspended. Bring it to the foreground; new connections recover by themselves. |
| Other hotspot devices connect but have no internet | A firewall (firewalld on Fedora-based distros) refusing to forward. Check `sudo firewall-cmd --get-active-zones`; the hotspot is normally in `nm-shared`. |
| Voice calls hang at "Checking route" | Phone app older than this fork's `main`. Check its log for `UDP send failed`. |
