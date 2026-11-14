#!/usr/bin/env bash
# End-to-end check of the Tailscale exit node -> mitmproxy (TUN mode) setup.
#
# Spins up a throwaway tailnet (headscale) plus a client node, points the client
# at the mitm exit node and verifies that HTTP / HTTPS / DNS(UDP) / QUIC(HTTP/3)
# / IPv6 traffic shows up in mitmproxy. Needs nothing but Docker and internet.
#
#   ./test/run.sh          # run and tear down
#   KEEP=1 ./test/run.sh   # leave the stack running (mitmweb: http://127.0.0.1:18085)
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=mitm-test
WEB=http://127.0.0.1:18085
PW=test-password
CURL_H3_IMAGE="alpine/curl-http3@sha256:b0cb55696adcaf5714958926a28ce78a5fa72f6a4aa8df2ec5b72f1cde8038e3"
export WEB_PASSWORD=$PW

FILES=(-f compose.yml -f test/compose.yml)
[ "${TEST_NO_IPV6:-}" = 1 ] && FILES+=(-f test/compose.no-ipv6.yml)
C() { docker compose -p "$PROJECT" "${FILES[@]}" "$@"; }
hs() { C exec -T headscale headscale "$@"; }
client() { C exec -T client "$@"; }
log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail=0
check() { # check <name> <cmd...>
  local name=$1; shift
  if "$@"; then echo "PASS  $name"; else echo "FAIL  $name"; fail=1; fi
}
not() { ! "$@" 2>/dev/null; }
retry() { # retry <tries> <cmd...>
  local n=$1; shift
  for _ in $(seq "$n"); do "$@" && return 0; sleep 1; done
  return 1
}

cleanup() { [ "${KEEP:-}" = 1 ] || C down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "reset"
C down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf test/.state && mkdir -p test/.state/mitmproxy

log "start headscale"
C up -d headscale
retry 30 hs users list >/dev/null
hs users create test >/dev/null
TS_AUTHKEY=$(hs preauthkeys create -u 1 --reusable -e 1h | tail -1)
export TS_AUTHKEY

log "start exit node + mitmproxy + client"
C up -d
node_id() { hs nodes list -o json | jq -r --arg n "$1" '.[] | select(.given_name==$n) | .id'; }
both_online() { [ "$(hs nodes list -o json | jq '[.[] | select(.online)] | length')" = 2 ]; }
retry 60 both_online
EXIT_ID=$(node_id mitm-exit)
EXIT_IP=$(hs nodes list -o json | jq -r '.[] | select(.given_name=="mitm-exit") | .ip_addresses[0]')
hs nodes approve-routes -i "$EXIT_ID" -r 0.0.0.0/0,::/0 >/dev/null
retry 30 test -s test/.state/mitmproxy/mitmproxy-ca-cert.pem

log "client: install tools, use exit node $EXIT_IP"
client apk add -q curl bind-tools >/dev/null
C cp test/.state/mitmproxy/mitmproxy-ca-cert.pem client:/ca.pem
retry 30 client tailscale set --exit-node="$EXIT_IP"
client tailscale ping -c 3 "$EXIT_IP" || true
C logs router

V6_UPLINK=0
C exec -T router ip -6 route show default | grep -q . && V6_UPLINK=1

log "traffic"
check "HTTP (IPv4)"                 client curl -4 -fsS -m 10 -o /dev/null http://example.com
check "mitm.it serves the CA cert"  sh -c "docker compose -p $PROJECT ${FILES[*]} exec -T client curl -4 -fsS -m 10 http://mitm.it/cert/pem | cmp -s - test/.state/mitmproxy/mitmproxy-ca-cert.pem"
check "HTTPS w/o mitm CA is rejected" not client curl -4 -fsS -m 10 -o /dev/null https://example.com
check "HTTPS (IPv4) via mitm CA"    client curl -4 -fsS -m 10 --cacert /ca.pem -o /dev/null https://example.com
check "DNS over UDP"                client dig +short +time=3 +tries=2 @1.1.1.1 example.com A
check "HTTP/3 (QUIC over UDP)"      docker run --rm --network "container:${PROJECT}-client-1" -v "$PWD/test/.state/mitmproxy/mitmproxy-ca-cert.pem:/ca.pem:ro" \
                                      "$CURL_H3_IMAGE" curl -4 -fsS -m 15 --http3-only --cacert /ca.pem -o /dev/null https://cloudflare.com/cdn-cgi/trace
if [ "$V6_UPLINK" = 1 ]; then
  check "HTTPS (IPv6) via mitm CA"  client curl -6 -fsS -m 10 --cacert /ca.pem -o /dev/null https://ipv6.google.com
else
  echo "SKIP  IPv6: container has no IPv6 uplink (IPv6 is left un-intercepted so clients fall back to IPv4)"
  check "IPv6 is refused (not hung)" not client curl -6 -sS -m 10 -o /dev/null https://ipv6.google.com
fi
check "dual-stack HTTPS (default)"  client curl -fsS -m 15 --cacert /ca.pem -o /dev/null https://www.google.com

log "flows seen by mitmproxy"
curl -fsS -c test/.state/cookies -o /dev/null "$WEB/?token=$PW"
curl -fsS -b test/.state/cookies "$WEB/flows" > test/.state/flows.json
jq -r '.[] | [.type, (.client_conn.peername[0]), (.server_conn.address | "\(.[0]):\(.[1])"),
              (.request.http_version // ""), (.request.pretty_host // ""),
              ((.response.status_code // "") | tostring), (.error.msg // "")] | @tsv' test/.state/flows.json \
  | column -t -s $'\t'
flow() { jq -e "$1" test/.state/flows.json >/dev/null; }
CLIENT_IP=$(hs nodes list -o json | jq -r '.[] | select(.given_name=="test-client") | .ip_addresses[0]')
check "mitmproxy saw HTTP flow"     flow '[.[] | select(.type=="http" and .request.scheme=="http")] | length > 0'
check "mitmproxy saw HTTPS flow"    flow '[.[] | select(.type=="http" and .request.scheme=="https" and .request.http_version!="HTTP/3")] | length > 0'
check "mitmproxy saw DNS flow"      flow '[.[] | select(.type=="dns")] | length > 0'
check "mitmproxy saw HTTP/3 flow"   flow '[.[] | select(.type=="http" and .request.http_version=="HTTP/3")] | length > 0'
[ "$V6_UPLINK" = 1 ] && check "mitmproxy saw IPv6 flow" flow '[.[] | select(.server_conn.address[0] | test(":"))] | length > 0'
check "client tailnet IP is visible ($CLIENT_IP)" flow "[.[] | select(.client_conn.peername[0]==\"$CLIENT_IP\")] | length > 0"

log "result"
[ "$fail" = 0 ] && echo "ALL PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
