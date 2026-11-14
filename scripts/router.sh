#!/bin/sh
# Route traffic that arrives from the tailnet (i.e. exit-node traffic) into
# mitmproxy's TUN interface so that both TCP and UDP are intercepted.
#
# The TUN device is created here as a *persistent* interface owned by the
# mitmproxy user. mitmproxy then attaches to it without root / CAP_NET_ADMIN
# (and skips its own sysctl tweaks, which fail on the read-only /proc/sys of a
# container).
#
# Runs as a loop so that everything is restored if something gets reset.
set -u

TUN="${MITM_TUN:-mitm0}"
TABLE="${MITM_TABLE:-100}"
INTERVAL="${MITM_ROUTER_INTERVAL:-2}"
MITM_DIR="${MITM_DIR:-/mitmproxy_data}"

log() { echo "[router] $*"; }

# Same rule as the mitmproxy image's entrypoint uses to pick the mitmproxy uid/gid.
mitm_owner() {
  if [ -f "$MITM_DIR/mitmproxy-ca.pem" ]; then f="$MITM_DIR/mitmproxy-ca.pem"; else f="$MITM_DIR"; fi
  stat -c "%u %g" "$f"
}

ensure_tun() {
  set -- $(mitm_owner)
  if ! ip link show "$TUN" >/dev/null 2>&1; then
    ip tuntap add dev "$TUN" mode tun user "$1" group "$2" || return 1
    log "created persistent $TUN (uid=$1 gid=$2)"
  fi
  ip link set "$TUN" up
}

has_v6_uplink() { ip -6 route show default | grep -q .; }

ensure_routes() {
  if ! ip -4 rule show | grep -q "iif tailscale0 .*lookup $TABLE"; then
    ip -4 rule add iif tailscale0 lookup "$TABLE" priority 100 && log "added IPv4 rule"
  fi
  ip -4 route replace default dev "$TUN" table "$TABLE"
  ip -4 route replace throw 100.64.0.0/10 table "$TABLE" # tailnet 宛ては横取りしない

  # mitmproxy は TUN 上で TCP ハンドシェイクを自前で完了させるため、上流に IPv6 が無いのに
  # IPv6 を mitm0 へ流すと、端末からは「つながったのに即切断」に見えて IPv4 へのフォールバックが効かない。
  # 上流に IPv6 のデフォルトルートがあるときだけ流し、無ければ通常の転送（=到達不能応答）に任せる。
  if has_v6_uplink; then
    if ! ip -6 rule show | grep -q "iif tailscale0 .*lookup $TABLE"; then
      ip -6 rule add iif tailscale0 lookup "$TABLE" priority 100 && log "added IPv6 rule"
    fi
    ip -6 route replace default dev "$TUN" table "$TABLE"
    ip -6 route replace throw fd7a:115c:a1e0::/48 table "$TABLE"
  elif ip -6 rule show | grep -q "iif tailscale0 .*lookup $TABLE"; then
    ip -6 rule del iif tailscale0 lookup "$TABLE" priority 100 && log "no IPv6 uplink: removed IPv6 rule"
  fi
}

# tailscale は exit node として転送するパケットに印を付けて MASQUERADE する。
# mitm0 はアドレスを持たないので、mitm0 向けはその前に抜けさせる（mitmproxy には端末の tailnet IP が見える）。
ensure_nat() {
  for ipt in iptables ip6tables; do
    first=$($ipt -t nat -S POSTROUTING 2>/dev/null | sed -n 2p)
    if [ "$first" != "-A POSTROUTING -o $TUN -j RETURN" ]; then
      while $ipt -t nat -D POSTROUTING -o "$TUN" -j RETURN 2>/dev/null; do :; done
      $ipt -t nat -I POSTROUTING 1 -o "$TUN" -j RETURN && log "pinned $ipt nat bypass for $TUN"
    fi
  done
}

state=""
while :; do
  if ensure_tun && ensure_routes && ensure_nat; then
    [ "$state" = up ] || log "routing tailscale0 -> $TUN"
    state=up
  else
    [ "$state" = down ] || log "setup failed, retrying"
    state=down
  fi
  sleep "$INTERVAL"
done
