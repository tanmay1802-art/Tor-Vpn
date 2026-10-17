#!/usr/bin/env bash
#
# torvpn v2 — System-wide Tor transparent proxy + kill switch (Linux)
#
# Usage:
#   sudo torvpn on [--allow-lan] [--force]   Route ALL system traffic through Tor
#   sudo torvpn off                          Restore normal networking
#   sudo torvpn status                       Show leak-check status & exit IP
#   sudo torvpn newip                        New Tor identity (NEWNYM)
#   sudo torvpn loop [MIN [MAX]]             Rotate IP every MIN..MAX seconds (min 10)
#   sudo torvpn restart                      off, then on
#
# Flags:
#   --allow-lan   Keep LAN (10/8, 172.16/12, 192.168/16) reachable. Default: blocked.
#                 Keeps an SSH session alive only if the client is on the LAN.
#   --force       Proceed even though a (remote) SSH session will be cut off.
#
# Limitations: while ON, ping (ICMP), NTP and non-DNS UDP are blocked by design.
#
# Requires: systemd, iptables, tor, curl.  Tested design target: Debian/Kali/Ubuntu.
# License: MIT

set -u
umask 077

# ------------------------------------------------------------------ config
readonly VERSION="2.0.0"
readonly TOR_SOCKS_PORT=9050
readonly TOR_TRANS_PORT=9040
readonly TOR_DNS_PORT=9053
readonly TOR_CTRL_PORT=9051
readonly CHECK_URL="https://check.torproject.org/api/ip"
readonly BEGIN_MARK="# --- torvpn begin ---"
readonly END_MARK="# --- torvpn end ---"
readonly LEGACY_MARK="# --- added by torvpn --- do not edit below"
readonly TORRC="/etc/tor/torrc"
readonly STATE_DIR="/var/lib/torvpn"
readonly NAT_CHAIN="TORVPN"
readonly OUT_CHAIN="TORVPN_OUT"
readonly IN_CHAIN="TORVPN_IN"
readonly LAN_NETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16"

ALLOW_LAN=0
FORCE=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --allow-lan) ALLOW_LAN=1 ;;
        --force)     FORCE=1 ;;
        *)           ARGS+=("$a") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

# ------------------------------------------------------------------ output
if [[ -t 1 ]]; then
    C_G=$'\033[32m'; C_R=$'\033[31m'; C_B=$'\033[34m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
else
    C_G=""; C_R=""; C_B=""; C_Y=""; C_0=""
fi
info() { echo "${C_B}[*]${C_0} $*"; }
ok()   { echo "${C_G}[+]${C_0} $*"; }
err()  { echo "${C_R}[!]${C_0} $*" >&2; }
warn() { echo "${C_Y}[~]${C_0} $*"; }

usage() {
    cat <<EOF
torvpn v${VERSION}

Usage: sudo torvpn <command> [flags]

Commands:
  on        Route all system traffic through Tor (transparent proxy + kill switch)
  off       Restore normal networking
  status    Leak check, exit IP and location
  newip     Request a new Tor identity (NEWNYM via ControlPort)
  loop      Rotate identity every MIN..MAX seconds (random in range, min 10)
  restart   off, then on
  help      This help

Flags:
  --allow-lan   Allow LAN access while ON (default: blocked). Also keeps an SSH
                session alive, but ONLY if the SSH client is on the LAN.
  --force       Proceed even though an SSH session will be cut off

Notes:
  - Running 'on' over remote SSH cuts the session (replies are rejected).
    Run it from a local console.
  - While ON, ICMP (ping), NTP and all non-DNS UDP are blocked by design;
    only TCP and DNS are carried over Tor. This is not a bug.
  - Rules are not persistent: after a reboot traffic is direct until 'on'.
EOF
}

# ------------------------------------------------------------------ helpers
have() { command -v "$1" &>/dev/null; }

# true if $1 is an IPv4 address in the ranges --allow-lan covers
is_lan_ip() {
    [[ "$1" =~ ^(10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Must run as root (sudo torvpn ...)"
        exit 1
    fi
}

ensure_deps() {
    local c missing=0
    for c in tor iptables curl pgrep systemctl; do
        have "$c" || { missing=1; break; }
    done
    if (( missing )); then
        if have apt-get; then
            info "Installing required packages (tor, iptables, curl, procps)..."
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tor iptables curl procps >/dev/null
        else
            err "Missing tools and no apt-get found. Install tor, iptables, curl, procps manually."
            exit 1
        fi
    fi
}

tor_running() { pgrep -x tor >/dev/null 2>&1; }

# uid of the running tor process (numeric uid avoids user-name guessing / ps truncation)
tor_uid() {
    local p
    p=$(pgrep -x tor | head -n1) || return 1
    [[ -n "$p" ]] || return 1
    stat -c %u "/proc/$p" 2>/dev/null
}

restart_tor() {
    systemctl restart tor@default 2>/dev/null || systemctl restart tor
}

# ------------------------------------------------------------------ torrc
write_torrc() {
    info "Configuring $TORRC ..."
    [[ -f "${TORRC}.torvpn.bak" ]] || cp -p "$TORRC" "${TORRC}.torvpn.bak" 2>/dev/null || true
    # remove legacy (v1) block and any previous v2 block, then rewrite (idempotent)
    sed -i "/^${LEGACY_MARK}\$/,\$d" "$TORRC"
    sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$TORRC"
    cat >> "$TORRC" <<EOF
${BEGIN_MARK}
SocksPort 127.0.0.1:${TOR_SOCKS_PORT}
TransPort 127.0.0.1:${TOR_TRANS_PORT}
DNSPort 127.0.0.1:${TOR_DNS_PORT}
ControlPort 127.0.0.1:${TOR_CTRL_PORT}
CookieAuthentication 1
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
ClientOnly 1
SafeSocks 1
WarnUnsafeSocks 1
AvoidDiskWrites 1
${END_MARK}
EOF
}

# ------------------------------------------------------------------ Tor checks
tor_json() {
    curl -fsS --max-time 15 -x "socks5h://127.0.0.1:${TOR_SOCKS_PORT}" "$CHECK_URL" 2>/dev/null
}
direct_json() {   # goes through the system path (i.e. through the transparent proxy when ON)
    curl -fsS --noproxy '*' --max-time 20 "$CHECK_URL" 2>/dev/null
}
extract_ip() { grep -oE '"IP":"[0-9a-fA-F:.]+"' | head -n1 | cut -d'"' -f4; }

tor_ip() { tor_json | extract_ip; }

wait_tor_ready() {
    local i ip
    info "Waiting for Tor to bootstrap..."
    for i in $(seq 1 40); do
        ip=$(tor_ip)
        [[ -n "$ip" ]] && return 0
        sleep 2
    done
    return 1
}

direct_is_tor() {
    local i
    for i in 1 2 3; do
        direct_json | grep -q '"IsTor":true' && return 0
        sleep 2
    done
    return 1
}

wait_new_ip() {
    local old="$1" new="" t
    for t in $(seq 1 10); do
        sleep 3
        new=$(tor_ip)
        if [[ -n "$new" && "$new" != "$old" ]]; then
            echo "$new"; return 0
        fi
    done
    echo "$new"
}

cookie_path() {
    local p
    for p in /run/tor/control.authcookie /var/run/tor/control.authcookie /var/lib/tor/control_auth_cookie; do
        [[ -r "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

# Real "new identity" via ControlPort (more reliable than SIGHUP)
tor_newnym() {
    local ck hex reply
    ck=$(cookie_path) || return 1
    hex=$(od -An -v -tx1 "$ck" | tr -d ' \n')
    reply=$( {
        exec 3<>"/dev/tcp/127.0.0.1/${TOR_CTRL_PORT}" || exit 1
        printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$hex" >&3
        timeout 5 cat <&3
    } 2>/dev/null )
    [[ "$reply" == *"250 OK"*"250 OK"* ]]
}

# ------------------------------------------------------------------ IPv6 (full block)
disable_ipv6() {
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    if [[ ! -f "$STATE_DIR/ipv6.state" ]]; then
        {
            echo "all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)"
            echo "default=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)"
        } > "$STATE_DIR/ipv6.state"
    fi
    sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 2>/dev/null
}

restore_ipv6() {
    [[ -f "$STATE_DIR/ipv6.state" ]] || return 0
    local all def
    all=$(sed -n 's/^all=//p' "$STATE_DIR/ipv6.state")
    def=$(sed -n 's/^default=//p' "$STATE_DIR/ipv6.state")
    [[ -n "$all" ]] && sysctl -qw net.ipv6.conf.all.disable_ipv6="$all" 2>/dev/null
    [[ -n "$def" ]] && sysctl -qw net.ipv6.conf.default.disable_ipv6="$def" 2>/dev/null
    rm -f "$STATE_DIR/ipv6.state"
}

# ------------------------------------------------------------------ firewall
is_active() { iptables -t nat -C OUTPUT -j "$NAT_CHAIN" 2>/dev/null; }

must() {
    "$@" || { err "Command failed: $*"; remove_rules quiet; err "Rules rolled back. You are NOT protected."; exit 1; }
}

apply_v6_rules() {
    have ip6tables || return 1
    ip6tables -N "$OUT_CHAIN" &&
    ip6tables -A "$OUT_CHAIN" -o lo -j ACCEPT &&
    ip6tables -A "$OUT_CHAIN" -j REJECT &&
    ip6tables -I OUTPUT 1 -j "$OUT_CHAIN" &&
    ip6tables -N "$IN_CHAIN" &&
    ip6tables -A "$IN_CHAIN" -i lo -j ACCEPT &&
    ip6tables -A "$IN_CHAIN" -j DROP &&
    ip6tables -I INPUT 1 -j "$IN_CHAIN"
}

apply_rules() {
    local uid net
    uid=$(tor_uid) || { err "Cannot determine tor's uid (is tor running?)."; exit 1; }

    info "Applying firewall rules (tor uid=$uid)..."
    remove_rules quiet     # always start from a clean state

    # ---- IPv6: sysctl off + firewall block (belt and braces) ----
    disable_ipv6
    apply_v6_rules || warn "ip6tables unavailable/failed; relying on sysctl for IPv6 block."

    # ---- NAT: transparent redirect ----
    must iptables -t nat -N "$NAT_CHAIN"
    # 1. Tor's own traffic is never redirected (avoids loops)
    must iptables -t nat -A "$NAT_CHAIN" -m owner --uid-owner "$uid" -j RETURN
    # 2. ALL DNS (any destination, incl. 127.0.0.53 stub) -> Tor DNSPort
    must iptables -t nat -A "$NAT_CHAIN" -p udp --dport 53 -j REDIRECT --to-ports "$TOR_DNS_PORT"
    # 3. Tor "automap" virtual addresses (.onion etc.) must go to TransPort
    must iptables -t nat -A "$NAT_CHAIN" -d 10.192.0.0/10 -p tcp -j REDIRECT --to-ports "$TOR_TRANS_PORT"
    # 4. Loopback stays local
    must iptables -t nat -A "$NAT_CHAIN" -d 127.0.0.0/8 -j RETURN
    # 5. Optional LAN bypass
    if (( ALLOW_LAN )); then
        for net in $LAN_NETS; do
            must iptables -t nat -A "$NAT_CHAIN" -d "$net" -j RETURN
        done
    fi
    # 6. Everything else (TCP) -> Tor TransPort
    must iptables -t nat -A "$NAT_CHAIN" -p tcp --syn -j REDIRECT --to-ports "$TOR_TRANS_PORT"
    must iptables -t nat -I OUTPUT 1 -j "$NAT_CHAIN"

    # ---- FILTER OUTPUT: kill switch ----
    must iptables -N "$OUT_CHAIN"
    must iptables -A "$OUT_CHAIN" -m owner --uid-owner "$uid" -j ACCEPT
    must iptables -A "$OUT_CHAIN" -o lo -j ACCEPT
    must iptables -A "$OUT_CHAIN" -p udp --sport 68 --dport 67 -j ACCEPT      # DHCP only
    if (( ALLOW_LAN )); then
        for net in $LAN_NETS; do
            must iptables -A "$OUT_CHAIN" -d "$net" -j ACCEPT
        done
    fi
    # No generic ESTABLISHED accept: pre-existing direct connections die immediately.
    # No NTP / QUIC / ICMP / UDP leaks: anything not above is rejected.
    must iptables -A "$OUT_CHAIN" -p tcp -j REJECT --reject-with tcp-reset
    must iptables -A "$OUT_CHAIN" -j REJECT
    must iptables -I OUTPUT 1 -j "$OUT_CHAIN"

    # ---- FILTER INPUT: no unsolicited inbound ----
    must iptables -N "$IN_CHAIN"
    must iptables -A "$IN_CHAIN" -i lo -j ACCEPT
    must iptables -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    must iptables -A "$IN_CHAIN" -p udp --sport 67 --dport 68 -j ACCEPT        # DHCP reply
    if (( ALLOW_LAN )); then
        for net in $LAN_NETS; do
            must iptables -A "$IN_CHAIN" -s "$net" -j ACCEPT
        done
    fi
    must iptables -A "$IN_CHAIN" -j DROP
    must iptables -I INPUT 1 -j "$IN_CHAIN"
}

remove_rules() {
    local q="${1:-}"
    [[ -z "$q" ]] && info "Removing torvpn firewall rules..."

    while iptables -t nat -D OUTPUT -j "$NAT_CHAIN" 2>/dev/null; do :; done
    iptables -t nat -F "$NAT_CHAIN" 2>/dev/null
    iptables -t nat -X "$NAT_CHAIN" 2>/dev/null

    while iptables -D OUTPUT -j "$OUT_CHAIN" 2>/dev/null; do :; done
    iptables -F "$OUT_CHAIN" 2>/dev/null
    iptables -X "$OUT_CHAIN" 2>/dev/null
    while iptables -D INPUT -j "$IN_CHAIN" 2>/dev/null; do :; done
    iptables -F "$IN_CHAIN" 2>/dev/null
    iptables -X "$IN_CHAIN" 2>/dev/null

    if have ip6tables; then
        while ip6tables -D OUTPUT -j "$OUT_CHAIN" 2>/dev/null; do :; done
        ip6tables -F "$OUT_CHAIN" 2>/dev/null
        ip6tables -X "$OUT_CHAIN" 2>/dev/null
        while ip6tables -D INPUT -j "$IN_CHAIN" 2>/dev/null; do :; done
        ip6tables -F "$IN_CHAIN" 2>/dev/null
        ip6tables -X "$IN_CHAIN" 2>/dev/null
    fi
    restore_ipv6
}

# ------------------------------------------------------------------ commands
cmd_on() {
    if is_active; then
        warn "torvpn is already ON. Use 'restart' to re-apply."
        return 0
    fi
    local socks_ip ssh_ip

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        ssh_ip=${SSH_CONNECTION%% *}
        if (( ALLOW_LAN )) && is_lan_ip "$ssh_ip"; then
            warn "SSH from LAN host $ssh_ip: its session stays reachable (--allow-lan)."
        elif (( FORCE )); then
            warn "SSH from $ssh_ip detected: the session WILL be cut (--force given)."
        else
            warn "SSH from $ssh_ip detected. Once the rules apply, replies to it will be REJECTED"
            warn "and the session will hang. --allow-lan only helps if the client is on the LAN."
            err "Run this from a local console, or use --force to proceed anyway."
            exit 1
        fi
    fi

    ensure_deps
    write_torrc
    info "Restarting tor..."
    restart_tor || { err "Could not (re)start tor."; exit 1; }
    wait_tor_ready || { err "Tor did not become ready (no circuit). Check: journalctl -u tor@default"; exit 1; }
    socks_ip=$(tor_ip)
    [[ -n "$socks_ip" ]] || { err "Could not fetch exit IP via SOCKS."; exit 1; }
    ok "Tor is up. Exit IP (via SOCKS): ${C_G}${socks_ip}${C_0}"

    apply_rules

    info "Verifying that system traffic really goes through Tor..."
    if ! direct_is_tor; then
        err "Verification FAILED: system traffic is not confirmed to exit via Tor."
        remove_rules quiet
        err "Rules rolled back. You are NOT protected."
        exit 1
    fi
    ok "Verified: traffic exits through Tor."
    ok "torvpn is ON. IPv6 blocked, DNS via Tor, kill switch active."
    (( ALLOW_LAN )) && warn "LAN access is allowed (--allow-lan)."
    echo "    Status:   sudo torvpn status"
    echo "    New IP:   sudo torvpn newip"
    echo "    Auto IP:  sudo torvpn loop 15 30"
    echo "    Turn off: sudo torvpn off"
}

cmd_off() {
    if ! is_active; then
        warn "torvpn rules were not active; cleaning up leftovers anyway."
    fi
    remove_rules
    ok "torvpn is OFF. Normal networking restored (tor service left running)."
}

cmd_status() {
    local json ip country
    if is_active; then
        ok "Rules: ON"
    else
        warn "Rules: OFF"
    fi
    if ! tor_running; then
        warn "Tor: not running"
        return 0
    fi
    ok "Tor: running"

    if is_active; then
        json=$(direct_json)
        if [[ "$json" == *'"IsTor":true'* ]]; then
            ok "System path: exits through Tor"
        else
            err "System path: NOT confirmed through Tor (possible leak or Tor not ready)"
        fi
        ip=$(printf '%s' "$json" | extract_ip)
        if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == "1" ]]; then
            ok "IPv6: disabled"
        else
            err "IPv6: ENABLED (leak risk)"
        fi
    else
        ip=$(tor_ip)
    fi
    [[ -n "${ip:-}" ]] && ok "Tor exit IP: ${C_G}${ip}${C_0}"
    if [[ -n "${ip:-}" ]]; then
        country=$(curl -fsS --max-time 15 -x "socks5h://127.0.0.1:${TOR_SOCKS_PORT}" \
                  "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -d '\n')
        [[ -n "$country" ]] && info "Exit country: $country"
    fi
}

cmd_newip() {
    if ! tor_running; then
        err "Tor is not running. Run 'sudo torvpn on' first."
        exit 1
    fi
    local old new
    old=$(tor_ip)
    info "Requesting new identity (NEWNYM)..."
    if ! tor_newnym; then
        warn "ControlPort NEWNYM failed (run 'torvpn on' once to enable it); falling back to SIGHUP."
        pkill -HUP -x tor 2>/dev/null
    fi
    new=$(wait_new_ip "$old")
    if [[ -n "$new" && "$new" != "$old" ]]; then
        ok "New exit IP: ${C_G}${new}${C_0}   (was: ${old:-unknown})"
    elif [[ -n "$new" ]]; then
        warn "IP unchanged ($new): Tor picked the same exit again. Try again in a few seconds."
    else
        err "Could not fetch new exit IP; Tor may still be building circuits."
    fi
}

cmd_loop() {
    local min="${1:-15}" max="${2:-}"
    [[ "$min" =~ ^[0-9]+$ ]] || min=15
    if (( min < 10 )); then
        warn "Interval too low (Tor rate-limits NEWNYM). Using 10 seconds."
        min=10
    fi
    [[ -n "$max" && "$max" =~ ^[0-9]+$ ]] || max=$min
    (( max < min )) && max=$min

    is_active || { err "Run 'sudo torvpn on' first."; exit 1; }
    trap 'echo; info "Loop stopped. torvpn is still ON."; exit 0' INT TERM
    info "Rotating identity every ${min}-${max}s (random). Ctrl+C to stop."
    while true; do
        cmd_newip
        sleep $(( min + RANDOM % (max - min + 1) ))
    done
}

cmd_restart() {
    cmd_off
    sleep 1
    cmd_on
}

# ------------------------------------------------------------------ main
[[ -t 1 ]] && echo "${C_B}torvpn v${VERSION}${C_0} — transparent Tor + kill switch + IPv6 block"

case "${1:-help}" in
    on)             need_root; cmd_on ;;
    off)            need_root; cmd_off ;;
    status)         need_root; cmd_status ;;
    newip)          need_root; cmd_newip ;;
    loop)           need_root; shift; cmd_loop "$@" ;;
    restart)        need_root; cmd_restart ;;
    help|--help|-h) usage ;;
    *) err "Unknown command: $1"; usage; exit 1 ;;
esac
