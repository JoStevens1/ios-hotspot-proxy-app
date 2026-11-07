# Laptop side

> **No package manager, or an immutable distro (Bazzite, Silverblue, SteamOS)?**
> Use [`portable/`](portable/README.md) instead: one script and the standalone
> sing-box binary in a folder, nothing installed.

The phone serves SOCKS5 on `10.42.0.10:9876`. This directory makes **every**
process on the laptop go through it — including applications that ignore proxy
settings, which is most games — by way of a local TUN device and
[sing-box](https://sing-box.sagernet.org/).

## ⚠️ Read this before you start it

**This laptop has no internet uplink of its own.** Everything it can reach comes
out through the phone. Two consequences that matter more than anything else here:

1. **`route_exclude_address` in `sing-box.json` is load-bearing.** If it fails to
   cover the phone's address, sing-box captures the very traffic it uses to reach
   the phone, tunnels it into itself, and the machine loses its only path out with
   no automatic recovery. This is why `preflight.py` exists and why `start.sh`
   runs it before anything else.
2. **`./teardown.sh` is how you come back.** Stopping the tunnel takes the machine
   offline. That is correct behaviour, not a bug — but know the command.

Do not `systemctl enable` this. Start it when you want it.

## Setup

```sh
./install.sh     # installs sing-box (pacman), validates config, installs unit
```

Nothing is started or enabled. `install.sh` prints the next steps when done.

## Running it

The phone must be running SocksBypass first — joined to this laptop's access
point, relay started, showing `10.42.0.10:9876`.

```sh
./start.sh              # preflight, then start
./verify.sh             # acceptance tests
./teardown.sh           # emergency stop
```

`start.sh` accepts an explicit phone address if it has changed:

```sh
./start.sh 10.42.0.77
```

which re-verifies the loop guard against that address rather than the one baked
into the config.

## The preflight guard

```sh
./preflight.py --self-test     # 7 cases, no device or root needed
./preflight.py -c sing-box.json
```

The self-test runs against the shipped `sing-box.json` rather than a copy, so it
is a real assertion about the real file. It covers the configuration that would
actually brick the machine — a stale subnet that no longer contains the phone —
along with an empty exclude list, a phone that has moved, a missing loopback
exclusion, and a config with no socks outbound at all.

## What `verify.sh` checks

| # | Test | Proves |
|---|------|--------|
| 0 | prerequisites | service up, phone reachable, SOCKS port open |
| 1 | direct egress baseline | the IP traffic takes when nothing is tunnelled |
| 2 | TCP through the tunnel | egress IP **changes** to the phone's carrier IP |
| 3 | system-wide routing | plain `curl` with no proxy flag is still captured |
| 4 | DNS leak | no port-53 traffic on the uplink |
| 5 | UDP | the clash API shows live UDP flows |

Test 2 failing because "the IPs are the same" is a *pass-shaped* failure: it
usually means the SOCKS fetch silently failed and fell through to the old
tunnel. Test 3 is the one that distinguishes a real system-wide TUN from a proxy
setting that only the test knew about.

**Proxy env variables:** this machine sets both lowercase (`all_proxy`,
`http_proxy`) and uppercase (`HTTP_PROXY`, `HTTPS_PROXY`) forms. Unsetting only
one leaves the other live, and a supposedly-direct request goes out via the old
iSH tunnel instead — producing a false pass. `verify.sh` clears both casings
before every network call.

## Watching traffic live

```sh
curl -s http://127.0.0.1:9090/connections | jq
```

The clash API is on loopback, which is excluded from the TUN, so it stays
reachable no matter what the tunnel is doing. Both `127.0.0.0/8` and `::1/128`
must stay excluded — `curl localhost:9090` resolves `::1` first, and without it
the query to inspect the tunnel would itself go through the tunnel.

## Configuration notes

- **`mtu: 1280`** — Path MTU Discovery needs an ICMP "fragmentation needed"
  reply, and SOCKS5 has no ICMP mechanism at all. There is no way to discover
  the real MTU, so it is set conservatively. Costs ~200 bytes per packet, which
  is irrelevant when the cellular link is the bottleneck.
- **`strict_route: true`** — traffic the TUN cannot handle becomes unreachable
  rather than leaking around the tunnel. Combined with the fact that there is no
  other uplink, this means unsupported traffic fails loudly instead of silently
  escaping.
- **Multicast and broadcast are rejected** — SOCKS5 UDP is unicast-only, so
  `224.0.0.0/4` and `ff00::/8` are refused locally instead of blackholing.
- **Do not add `-derivedDataPath`-style cleverness to the build**, and do not
  change `route_exclude_address` without re-running `./preflight.py --self-test`.

## Still to do

The Steam multiplayer question is **not** answered by this directory. UDP flows
will show up in the clash API; whether a given game's traffic survives the
single shared UDP socket in the phone app is an empirical question. Run
`./verify.sh`, get a clean test 5, then try a UDP-heavy non-competitive title and
watch `curl -s http://127.0.0.1:9090/connections | jq` while it runs.
