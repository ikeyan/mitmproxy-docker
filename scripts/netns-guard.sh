#!/bin/sh
# Runs "$@" and exits when this container has been left behind in a stale
# network namespace.
#
# tailscale and mitmproxy share router's network namespace
# (network_mode: service:router). If router is restarted or recreated, it gets
# a fresh namespace, but containers that already joined keep the old, now
# disconnected one (it no longer has eth0). Exiting lets Docker's restart
# policy start us again, which joins router's current namespace.
"$@" &
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null' TERM INT

while kill -0 "$pid" 2>/dev/null; do
  if ! grep -q '^ *eth0:' /proc/net/dev; then
    echo "[netns-guard] eth0 is gone (router was restarted); exiting to re-join its network namespace" >&2
    kill -TERM "$pid" 2>/dev/null
    wait "$pid"
    exit 1
  fi
  sleep 3
done
wait "$pid"
