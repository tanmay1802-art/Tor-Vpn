# torvpn

[![shellcheck](https://github.com/<your-username>/torvpn/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/<your-username>/torvpn/actions/workflows/shellcheck.yml)
![license](https://img.shields.io/badge/license-MIT-blue)
![shell](https://img.shields.io/badge/shell-bash-green)

**A single-file Bash tool that routes all of a Linux machine's TCP traffic and DNS through Tor (a "VPN-style" on/off switch), with a leak-proof kill switch, IPv6 blocking, and verified identity rotation.**

```bash
sudo torvpn on        # everything now exits through Tor
sudo torvpn status    # leak check + exit IP
sudo torvpn loop 15 30  # new Tor identity every 15-30 s (random)
sudo torvpn off       # back to normal networking
```

> **Scope note:** this is a learning / portfolio project that wraps Tor's official `TransPort` + `iptables`. It is **not** a replacement for [Tails](https://tails.net) or [Whonix](https://www.whonix.org). See [Limitations](#limitations--threat-model).

---

## Table of contents

1. [Why this project](#why-this-project)
2. [Features](#features)
3. [How it works](#how-it-works)
4. [Quick start (Kali / Debian / Ubuntu)](#quick-start-kali--debian--ubuntu)
5. [Command reference](#command-reference)
6. [Verify it really works (test checklist)](#verify-it-really-works-test-checklist)
7. [Version history: problems found and how they were fixed](#version-history-problems-found-and-how-they-were-fixed)
8. [Code walkthrough](#code-walkthrough)
9. [Limitations & threat model](#limitations--threat-model)
10. [Troubleshooting](#troubleshooting)
11. [Repository layout](#repository-layout)
12. [Development notes](#development-notes)
13. [Responsible use](#responsible-use)
14. [License](#license)

---

## Why this project

Most "Tor IP changer" scripts only reload Tor and print a new IP. That changes the IP *of one SOCKS client*, but every other program on the machine still connects directly and leaks the real address.

I wanted a tool that:

- forces **all** system traffic through Tor, not just one app,
- **fails closed**: if Tor dies or a rule is wrong, traffic is blocked rather than leaked,
- **proves** it works (instead of assuming), and
- can be turned on and off with one command, like a VPN.

## Features

| Feature | What it does |
|---|---|
| Transparent proxy | `iptables` NAT redirects all outgoing TCP to Tor's `TransPort` |
| DNS leak protection | All UDP/53 (any destination, including the `127.0.0.53` stub resolver) goes to Tor's `DNSPort` |
| Kill switch | Dedicated `OUTPUT` chain rejects everything that is not Tor itself, loopback, or DHCP |
| IPv6 blocked | Disabled through both `sysctl` and `ip6tables`; the previous sysctl values are saved and restored on `off` |
| Inbound lockdown | Dedicated `INPUT` chain drops unsolicited inbound traffic |
| Verified activation | After `on`, queries `check.torproject.org` through the *normal system path* and **rolls everything back** if it is not Tor |
| Real identity rotation | Uses Tor's `ControlPort` `SIGNAL NEWNYM` (cookie auth) with a randomised interval for `loop` |
| Safe on/off | Idempotent cleanup through named chains; `off` can always be re-run |
| SSH guard | Refuses to enable over remote SSH (it would cut the session) unless forced |
| Non-destructive config | Edits `torrc` only between marker lines and keeps a `.torvpn.bak` backup |
| Linted | `shellcheck` runs in GitHub Actions on every push |

## How it works

```
 any app (browser, curl, apt, ...)
        |
        |  new TCP connection / DNS query
        v
 +---------------------------------------------------+
 | iptables  nat OUTPUT -> chain TORVPN              |
 |   tor's own uid ............ RETURN (no loop)     |
 |   UDP/53 .................. REDIRECT -> :9053     |
 |   10.192.0.0/10 (automap) . REDIRECT -> :9040     |
 |   127.0.0.0/8 ............. RETURN                |
 |   [--allow-lan: LAN ranges  RETURN]               |
 |   other TCP SYN ........... REDIRECT -> :9040     |
 +---------------------------------------------------+
        |
        v
   Tor TransPort :9040 / DNSPort :9053 (127.0.0.1)
        |
        v
   Tor network  ->  exit node  ->  destination

 filter OUTPUT -> chain TORVPN_OUT (kill switch)
   tor uid ACCEPT | lo ACCEPT | DHCP ACCEPT | [LAN ACCEPT]
   everything else: REJECT   (so a failed redirect can never leak)

 filter INPUT  -> chain TORVPN_IN
   lo ACCEPT | ESTABLISHED,RELATED ACCEPT | DHCP reply ACCEPT | DROP

 ip6tables: OUTPUT/INPUT allow only loopback, everything else blocked
 sysctl:    net.ipv6.conf.{all,default}.disable_ipv6 = 1
```

`sudo torvpn on` runs these steps in order:

1. Check/install dependencies (`tor`, `iptables`, `curl`, `procps`).
2. Rewrite the managed block in `/etc/tor/torrc` (ports, ControlPort, automap).
3. Restart Tor and wait until it has built a circuit.
4. Read the numeric uid Tor runs as (so Tor's own traffic is exempt).
5. Apply IPv6 blocking, NAT redirect rules, kill switch and input rules. Any failing command triggers an automatic rollback.
6. **Verify** that a plain `curl` (no proxy settings) now reports `"IsTor":true`. If not, roll back and exit with an error.

## Quick start (Kali / Debian / Ubuntu)

> Run this in a **local console or a VM**. Do not run it over a remote SSH session (see [SSH guard](#ssh-guard)).

### 1. Install the prerequisites

```bash
sudo apt update
sudo apt install -y git tor iptables curl procps
```

`torvpn` can also install missing packages itself on Debian-family systems, but installing them first makes errors easier to read.

### 2. Get the code

```bash
git clone https://github.com/<your-username>/torvpn.git
cd torvpn
chmod +x torvpn.sh
```

### 3. Run it

```bash
sudo ./torvpn.sh on
```

Expected output (abridged):

```
[*] Configuring /etc/tor/torrc ...
[*] Restarting tor...
[*] Waiting for Tor to bootstrap...
[+] Tor is up. Exit IP (via SOCKS): 185.xxx.xxx.xxx
[*] Applying firewall rules (tor uid=...)...
[*] Verifying that system traffic really goes through Tor...
[+] Verified: traffic exits through Tor.
[+] torvpn is ON. IPv6 blocked, DNS via Tor, kill switch active.
```

Check it:

```bash
sudo ./torvpn.sh status
curl https://check.torproject.org/api/ip      # {"IsTor":true,"IP":"..."}
```

Turn it off:

```bash
sudo ./torvpn.sh off
```

### 4. (Optional) Install as a command

```bash
sudo install -m 755 torvpn.sh /usr/local/bin/torvpn
sudo torvpn on
sudo torvpn status
sudo torvpn off
```

To remove it later:

```bash
sudo torvpn off
sudo rm /usr/local/bin/torvpn
sudo rm -rf /var/lib/torvpn
# optional: restore the original Tor config
sudo cp /etc/tor/torrc.torvpn.bak /etc/tor/torrc
```

### Running inside VirtualBox

Works in a Kali VM with a **NAT** or **bridged** adapter. Use the VM console (not SSH from the host) the first time. Take a VM snapshot beforehand if you want an easy way back.

## Command reference

| Command | Description |
|---|---|
| `on [--allow-lan] [--force]` | Enable system-wide Tor routing, kill switch and IPv6 block |
| `off` | Remove all rules, restore IPv6 settings (Tor service keeps running) |
| `status` | Rules state, Tor state, whether the system path really exits via Tor, IPv6 state, exit IP and country |
| `newip` | Request a new identity (`NEWNYM`) and wait for the exit IP to change |
| `loop [MIN [MAX]]` | Rotate identity every `MIN`..`MAX` seconds (random within the range, minimum 10). `Ctrl+C` stops the loop; the VPN stays on |
| `restart` | `off` then `on` |
| `help` | Usage |

Flags:

| Flag | Meaning |
|---|---|
| `--allow-lan` | Leave 10/8, 172.16/12, 192.168/16, 169.254/16 reachable (default: blocked). Also keeps an SSH session alive **only if the SSH client is on the LAN** |
| `--force` | Proceed even though a remote SSH session will be cut off |

Examples:

```bash
sudo torvpn on                 # normal
sudo torvpn on --allow-lan     # keep access to the local network / printers / NAS
sudo torvpn loop               # new identity every 15 s
sudo torvpn loop 20 45         # random 20-45 s
```

### SSH guard

If `SSH_CONNECTION` is set, `on` warns and exits, because once the rules apply the replies to your SSH client are rejected and the session hangs. Run it from a local console, or use `--allow-lan` when the client is on the LAN, or `--force` if you accept being cut off.

## Verify it really works (test checklist)

Run these after `sudo torvpn on`. They are the tests I used to decide whether the tool is trustworthy, and they are worth re-running after any change.

| # | Test | Command | Expected |
|---|---|---|---|
| 1 | System traffic is Tor | `curl https://check.torproject.org/api/ip` | `"IsTor":true` |
| 2 | Exit IP differs from real IP | compare with your real IP (check before `on`) | Different |
| 3 | IPv6 is blocked | `curl -6 --max-time 5 https://ifconfig.co` | Fails / times out |
| 4 | No DNS leaves the machine | `sudo tcpdump -ni eth0 port 53` in one terminal, `nslookup example.com` in another (replace `eth0` with your interface) | **No packets** on the physical interface |
| 5 | Kill switch (fail closed) | `sudo systemctl stop tor@default; curl --max-time 8 https://example.com` | Fails (no direct connection). Restart with `sudo systemctl start tor@default` |
| 6 | Ping is blocked by design | `ping -c1 8.8.8.8` | Rejected |
| 7 | New identity works | `sudo torvpn newip` | Exit IP changes (usually within ~30 s) |
| 8 | Clean rollback | `sudo torvpn off; curl https://check.torproject.org/api/ip` | `"IsTor":false`, normal connectivity restored |
| 9 | Idempotent | run `on` twice, `off` twice | No errors, no duplicated rules (`sudo iptables -S OUTPUT` shows one jump) |
| 10 | Rules inspection | `sudo iptables -t nat -S TORVPN; sudo iptables -S TORVPN_OUT` | Matches the diagram above |

**Tested on:** _fill in after running the checklist (distribution, version, VM or bare metal, date)._

## Version history: problems found and how they were fixed

This repository contains v2. v1 was the first working version (a Tor toggle plus a separate Tor IP-changer script). Reviewing it with a leak-testing mindset exposed the issues below. Each one is a real design lesson.

| # | v1 behaviour (problem) | Why it matters | v2 fix |
|---|---|---|---|
| 1 | `TransPort`/`DNSPort` bound to `127.0.0.2` | `iptables -j REDIRECT` sends locally generated packets to `127.0.0.1`, so redirected connections would not reach Tor | Bind all Tor ports to `127.0.0.1` |
| 2 | `10.192.0.0/10` (Tor's automap virtual range) was in the "private ranges, RETURN" list | Automapped hostnames (and `.onion` lookups) bypass `TransPort` and fail | Redirect the virtual range to `TransPort` *before* the private-range bypass |
| 3 | IPv6 untouched | Any IPv6-capable destination bypasses IPv4-only rules: a classic real-IP leak | `sysctl` disable **and** `ip6tables` blocking; previous sysctl values saved and restored |
| 4 | NTP and `67:68` UDP accepted directly; broad `ESTABLISHED,RELATED` accept | NTP reveals the real IP; the `ESTABLISHED` accept let connections opened *before* enabling keep running directly | DHCP only (`68 -> 67`); no generic ESTABLISHED accept on `OUTPUT`, so old direct flows die; everything else is rejected |
| 5 | Kill switch built by appending and deleting individual rules | Fragile: a changed rule order or a partial failure leaves stale rules; cleanup could miss entries | Named chains (`TORVPN`, `TORVPN_OUT`, `TORVPN_IN`) hooked at the top of the built-in chains; cleanup flushes and deletes the chains |
| 6 | New identity via `kill -HUP` | `SIGHUP` reloads configuration; it is not the documented way to get a fresh identity | `ControlPort` + cookie authentication + `SIGNAL NEWNYM`; falls back to `SIGHUP` only if the ControlPort is unavailable |
| 7 | No check that traffic is actually routed through Tor | A misconfiguration could silently leave the user exposed while the tool reports success | Post-activation test against `check.torproject.org` on the normal system path; automatic rollback on failure |
| 8 | Tor readiness = `tor.service` is active | On Debian, `tor.service` is a wrapper that reports active even if the real instance (`tor@default`) failed; the SOCKS port opens before bootstrap finishes | Restart `tor@default` (fallback `tor`), then poll until a real circuit returns an exit IP |
| 9 | Tor's user found by name (`debian-tor`, guessed fallback) | Wrong guess = Tor's own traffic gets redirected into itself (loop) or rule creation fails | Read the numeric uid from `/proc/<pid>` of the running Tor process |
| 10 | HTTP IP-check endpoints; `off` queried the "real IP" | Plain HTTP can be tampered with; the `off` check sent the real IP to a third party every time | HTTPS Tor-project endpoint that also states `IsTor`; no real-IP lookup on `off` |
| 11 | TCP/53 redirected to `DNSPort` | Tor's `DNSPort` is UDP only; TCP DNS would be refused | Only UDP/53 goes to the `DNSPort`; TCP/53 flows through `TransPort` |
| 12 | `systemctl enable tor` run silently | Changed boot behaviour without the user asking | Removed |
| 13 | IP changer: unvalidated input, `-eq 0` logic made the loop infinite if *either* value was 0, fixed interval | Crashes on non-numeric input; a predictable rotation pattern | Numeric validation, minimum 10 s (Tor rate-limits `NEWNYM`), random interval in a `MIN..MAX` range, clean `Ctrl+C` handling |
| 14 | No inbound filtering, no SSH lockout protection | Unsolicited inbound traffic accepted; enabling over SSH silently bricked the session | `INPUT` default drop; SSH guard with client-IP detection |
| 15 | Rules applied without error handling | A failed command mid-way left a half-configured firewall | Every rule goes through `must`, which rolls everything back on any failure |

**Fixed in a later review pass:** the SSH check initially treated `--allow-lan` as a universal escape, but it only helps when the SSH client is on the LAN; the check now detects the client IP and says so. A cosmetic bug that could print an empty exit IP was also fixed.

## Code walkthrough

Everything is in `torvpn.sh` (about 500 lines). Key functions, in file order:

| Function | Purpose |
|---|---|
| argument loop | Pulls `--allow-lan` / `--force` out of the arguments so positional arguments (`loop 15 30`) still work; uses the `${ARGS[@]+"${ARGS[@]}"}` idiom to be safe under `set -u` with empty arrays |
| `tor_uid` | Numeric uid of the running Tor process, used in `--uid-owner` rules |
| `write_torrc` | Backs up `torrc` once, deletes any previous managed block (and the legacy v1 block), appends a marker-delimited block |
| `tor_json`, `direct_json`, `tor_ip` | Two different views: *via the SOCKS port* vs. *via the normal system path* (which is what proves the transparent proxy works) |
| `wait_tor_ready` | Polls until Tor can actually fetch the check URL |
| `tor_newnym` | Opens `/dev/tcp/127.0.0.1/9051`, authenticates with the cookie (hex-encoded with `od`), sends `SIGNAL NEWNYM`, checks both replies for `250 OK` |
| `disable_ipv6` / `restore_ipv6` | Saves and restores the original sysctl values in `/var/lib/torvpn` |
| `apply_rules` | Builds the NAT chain, kill-switch chain and input chain; every command wrapped in `must` |
| `remove_rules` | Idempotent teardown; safe to call at any time (also used as "start clean" at the beginning of `apply_rules`) |
| `cmd_on` | Orchestrates: SSH guard, dependencies, torrc, Tor restart, readiness wait, rules, verification, rollback |
| `cmd_status` | Reports rules, Tor, system path, IPv6 state, exit IP/country. Only does the direct (system path) check while ON, so `status` never sends the real IP to a web service |
| `cmd_loop` | Random sleep with `$(( min + RANDOM % (max - min + 1) ))`; traps `INT`/`TERM` |

## Limitations & threat model

**What it is designed to protect against**

- Applications connecting directly and exposing the machine's real IP address.
- DNS queries reaching the ISP or a configured resolver.
- IPv6 leaks.
- Leaks caused by Tor stopping unexpectedly (traffic is blocked, not sent directly).

**What it does NOT protect against**

- **Browser fingerprinting, cookies and logins.** Use Tor Browser for web browsing. Logging into a personal account identifies you no matter how you connect.
- **Malware or a compromised host.** If the operating system is compromised, nothing here helps.
- **Application-level leaks.** Programs can send identifying data (hostname, account IDs, telemetry) *through* Tor.
- **Traffic correlation** by a very powerful network observer.
- **Stream isolation.** A transparent proxy puts every application on shared circuits, so different activities can be linked. Isolated per-application circuits need SOCKS-based configuration or an architecture like Whonix.
- **Visible Tor use.** Your ISP can see that you connect to the Tor network (bridges are not configured).
- **LAN-level identifiers.** The MAC address and hostname are visible on the local network.

**Behaviour you might mistake for a bug**

- Only **TCP and DNS** are carried. UDP applications (VoIP, games, QUIC/HTTP3) do not work while ON, by design.
- **Ping (ICMP) and NTP are blocked.** With NTP blocked, the clock can drift on long sessions; Tor needs a roughly correct clock.
- **Not persistent:** rules disappear on reboot, and the machine uses direct networking until `torvpn on` is run again.
- **IPv6 is disabled system-wide** while ON and restored on `off`.
- **Auto-install uses `apt`.** On other distributions, install `tor`, `iptables`, `curl` and `procps` manually.
- `iptables` here means whichever backend the distribution provides (`iptables-nft` on current Kali/Debian).

**Rotating the exit IP very frequently** puts load on the Tor network and does not make you more anonymous. The minimum interval is 10 seconds for that reason.

If you need strong guarantees, use **Tails** (live system, forced Tor, amnesic) or **Whonix** (gateway/workstation VMs).

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Tor did not become ready` | Check `journalctl -u tor@default -e`. No network, a wrong system clock, or a blocked Tor network (use bridges outside this tool) |
| `Verification FAILED` and rollback | The redirect did not work. Check `sudo iptables -t nat -S TORVPN` and that Tor listens: `ss -ltn \| grep -E '9040\|9050\|9051'` |
| No internet after `on` | By design anything that is not TCP/DNS is blocked. Try `curl https://example.com`. Run `sudo torvpn off` to return to normal |
| Stuck / odd state after a crash | `sudo torvpn off` always cleans up (it is idempotent) |
| Cannot reach local devices | Use `sudo torvpn on --allow-lan` |
| SSH session hangs | You enabled it over SSH; reconnect from the console and run `sudo torvpn off` |
| `NEWNYM failed` | Run `sudo torvpn on` once so the ControlPort is configured; check the cookie file at `/run/tor/control.authcookie` |
| IP did not change | Tor chose the same exit again. Try again in a few seconds |

Useful inspection commands:

```bash
sudo iptables -t nat -S TORVPN
sudo iptables -S TORVPN_OUT
sudo iptables -S TORVPN_IN
sudo ip6tables -S TORVPN_OUT
sudo journalctl -u tor@default -e
```

## Repository layout

```
torvpn/
├── torvpn.sh                        # the tool (single file)
├── README.md
├── LICENSE
└── .github/workflows/shellcheck.yml # lint on every push / PR
```

## Development notes

- Written in Bash with `set -u` and a defensive style (`must`, idempotent cleanup, no hidden global state except the saved IPv6 sysctl values in `/var/lib/torvpn`).
- v2 was developed with AI assistance (Claude by Anthropic) for design review, the rewrite and the documentation, and then reviewed by the author. The test checklist above exists so the behaviour can be verified independently rather than trusted.
- Lint locally with `shellcheck -S warning torvpn.sh`.

Ideas for future work:

- [ ] Optional whitelist of the SSH client's IP so remote use survives activation
- [ ] Persistence option (rules restored at boot) with a systemd unit
- [ ] `nftables` backend
- [ ] Bridge / pluggable transport support
- [ ] Per-application stream isolation via a SOCKS mode
- [ ] Automated integration tests in a network namespace

## Responsible use

Tor is a legitimate privacy tool. Use this software only on systems you own or administer and in accordance with the laws that apply to you. It is provided as-is, without warranty, and does not guarantee anonymity.

## License

MIT, see [LICENSE](LICENSE).
