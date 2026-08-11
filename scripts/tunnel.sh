#!/usr/bin/env bash
#
# Tailscale Serve in front of the local API, so a physical iPhone can reach it.
#
# The app carries no ATS exception on purpose, so a device needs https and a real
# certificate — which is what Serve gives, for a hostname that belongs to this
# Mac rather than to a tunnel vendor. See apps/ios/README.md.
#
#   ensure  assert the config, quietly, and never fail the caller. This is what
#           `make dev` runs: developing against the Simulator needs no tunnel at
#           all, so a missing or signed-out Tailscale is a note, not an error.
#   up      the same, but interactive — it will sit and wait while you enable
#           Serve on the tailnet, and it fails loudly if it can't finish.
#   status  what is registered, plus the lines that go in Debug.local.xcconfig.
#   stop    remove the mapping.
set -euo pipefail

MODE="${1:-ensure}"
PORT="${TUNNEL_PORT:-8443}"
BACKEND_PORT="${BACKEND_PORT:-8080}"

# Serve is off on a new tailnet until an owner turns it on in the admin console,
# and the CLI's response is to print that link and then block until somebody
# clicks it. That is the right behaviour for `make tunnel` and completely wrong
# for `make dev`, so `ensure` runs it on a leash.
ENSURE_TIMEOUT="${TUNNEL_TIMEOUT:-15}"

BLUE=$'\033[34m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RESET=$'\033[0m'

note() { printf '%s[tunnel]%s %s\n' "$BLUE" "$RESET" "$1"; }
warn() { printf '%s[tunnel]%s %s\n' "$YELLOW" "$RESET" "$1" >&2; }

# The CLI ships inside the app bundle when Tailscale came from the App Store,
# and on PATH when it came from Homebrew.
TS="$(command -v tailscale 2>/dev/null || true)"
if [[ -z "$TS" && -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
  TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
fi

# Every reason to give up, in one place, so `ensure` can shrug and `up` can
# exit non-zero on exactly the same conditions.
unavailable() {
  if [[ -z "$TS" ]]; then
    echo "Tailscale isn't installed — brew install --cask tailscale"
    return 0
  fi
  if ! "$TS" status --json >/dev/null 2>&1; then
    echo "Tailscale isn't running or isn't signed in — open the app"
    return 0
  fi
  return 1
}

# This machine's MagicDNS name, asked of tailscaled rather than written down:
# it differs per machine and per tailnet, and a stale one surfaces as a
# certificate error, which reads like a broken tunnel rather than a typo.
tailnet_host() {
  "$TS" status --json | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'
}

# `serve status --json` is {} when nothing is registered. Checking before
# writing is what keeps `ensure` free on every run after the first, and — more
# to the point — keeps it from re-entering the enablement wait.
is_registered() {
  "$TS" serve status --json 2>/dev/null | PORT="$PORT" python3 -c \
    'import json, os, sys
port = os.environ["PORT"]
try:
    cfg = json.load(sys.stdin) or {}
except ValueError:
    sys.exit(1)
# Two ways of asking, because one is a map keyed by port and the other by
# host:port, and a shape change in either alone would silently re-register on
# every run — which is the one thing this check exists to prevent.
if port in (cfg.get("TCP") or {}):
    sys.exit(0)
if any(str(k).endswith(":" + port) for k in (cfg.get("Web") or {})):
    sys.exit(0)
sys.exit(1)'
}

print_xcconfig() {
  local host
  host="$(tailnet_host)"
  printf '\n%sapps/ios/Configurations/Debug.local.xcconfig%s\n' "$BLUE" "$RESET"
  printf '%sAPI_SCHEME = https%s\n' "$GREEN" "$RESET"
  printf '%sAPI_HOSTNAME = %s:%s%s\n' "$GREEN" "$host" "$PORT" "$RESET"
  printf '\nThe iPhone has to be signed into the same tailnet. Rebuild after editing.\n'
}

register_bounded() {
  local out status=0 pid waited=0
  out="$(mktemp)"
  "$TS" serve --bg --https="$PORT" "http://127.0.0.1:$BACKEND_PORT" >"$out" 2>&1 &
  pid=$!

  while [[ $waited -lt $ENSURE_TIMEOUT ]] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    # Still going after the timeout: it is sitting on the enablement prompt,
    # which nothing here can answer. Hand the link over and get out of the way.
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    warn "Serve isn't enabled on this tailnet yet, so the phone can't reach the API."
    sed 's/^/  /' "$out" >&2
    warn "Enable it, then run: make tunnel"
    rm -f "$out"
    return 1
  fi

  wait "$pid" || status=$?
  if [[ $status -ne 0 ]]; then
    sed 's/^/  /' "$out" >&2
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  return 0
}

case "$MODE" in
  ensure)
    if reason="$(unavailable)"; then
      warn "$reason"
      warn "Skipping — the Simulator doesn't need it, a physical device does."
      exit 0
    fi
    if is_registered; then
      note "https://$(tailnet_host):$PORT -> 127.0.0.1:$BACKEND_PORT"
      exit 0
    fi
    note "registering :$PORT -> 127.0.0.1:$BACKEND_PORT"
    if register_bounded; then
      note "https://$(tailnet_host):$PORT -> 127.0.0.1:$BACKEND_PORT"
    fi
    # Never fatal: `make dev` has a database and an API to get on with.
    exit 0
    ;;

  up)
    if reason="$(unavailable)"; then
      warn "$reason"
      exit 1
    fi
    if is_registered; then
      note "already registered"
    else
      note "registering :$PORT -> 127.0.0.1:$BACKEND_PORT"
      # Unbounded on purpose. You asked for this one, so if Serve needs turning
      # on, the useful thing is to print the link and wait while you click it.
      "$TS" serve --bg --https="$PORT" "http://127.0.0.1:$BACKEND_PORT"
    fi
    "$TS" serve status || true
    print_xcconfig
    ;;

  status)
    if reason="$(unavailable)"; then
      warn "$reason"
      exit 1
    fi
    "$TS" serve status || true
    print_xcconfig
    ;;

  stop)
    if reason="$(unavailable)"; then
      warn "$reason"
      exit 1
    fi
    # Checked first because removing a mapping that isn't there is an error to
    # the CLI ("handler does not exist") and a no-op to anyone reading this.
    if ! is_registered; then
      note "nothing registered on :$PORT"
      exit 0
    fi
    "$TS" serve --https="$PORT" off
    note "removed :$PORT"
    ;;

  *)
    echo "usage: $(basename "$0") [ensure|up|status|stop]" >&2
    exit 2
    ;;
esac
