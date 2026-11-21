#!/usr/bin/env bash
#
# xui-export.sh — export all XHTTP + Hysteria2 client configs from a local
# 3x-ui / x-ui panel into one file (default: /root/all.txt), one link per line.
#
# Universal: no IP, domain or password is hardcoded. The script reads the
# panel SQLite DB to get the built-in subscription server settings and pulls
# every client's links from it on 127.0.0.1 — no panel login required.
# It works on any VPS with 3x-ui (or x-ui) installed.
#
# Usage:
#   bash xui-export.sh
#
# Environment:
#   OUT       output file (default: /root/all.txt)
#   KEEP_ALL  1 = export every link, not only xhttp + hy2 (default: 0)
#   XUI_DB    explicit path to x-ui.db (auto-detected by default)

set -u

OUT="${OUT:-/root/all.txt}"
KEEP_ALL="${KEEP_ALL:-0}"

log() { echo "[xui-export] $*"; }
die() { echo "[xui-export] ERROR: $*" >&2; exit 1; }

# ---- 1. find the panel database -------------------------------------------
find_db() {
  local p
  for p in "${XUI_DB:-}" /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db; do
    [ -n "$p" ] && [ -f "$p" ] && { echo "$p"; return 0; }
  done
  find /etc /usr/local /opt /root -maxdepth 5 -name x-ui.db -type f 2>/dev/null | head -1
}

DB="$(find_db)"
[ -n "$DB" ] || die "x-ui.db not found. Install 3x-ui first, or set XUI_DB=/path/to/x-ui.db"
log "panel DB: $DB"

# ---- 2. tiny DB query helper (sqlite3 or python3) --------------------------
dbq() {
  local sql="$1"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DB" "$sql" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$DB" "$sql" <<'PY'
import sqlite3, sys
con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
for row in con.execute(sys.argv[2]):
    print("|".join("" if v is None else str(v) for v in row))
PY
  else
    die "need 'sqlite3' or 'python3' to read the panel DB"
  fi
}

# ---- 3. subscription server settings --------------------------------------
sub_port="$(dbq "SELECT value FROM settings WHERE key='subPort'")"
sub_path="$(dbq "SELECT value FROM settings WHERE key='subPath'")"
sub_en="$(dbq "SELECT value FROM settings WHERE key='subEnable'")"
sub_listen="$(dbq "SELECT value FROM settings WHERE key='subListen'")"

[ -n "$sub_port" ] || die "subPort not found in panel settings"
case "$sub_en" in
  false|False|FALSE|0)
    die "the built-in subscription server is disabled. Enable it in the panel: Settings -> Basic -> Subscription, then re-run" ;;
esac

# subscription host: connect locally unless it is bound to a specific address
case "$sub_listen" in
  ""|0.0.0.0|"::"|"[::]") sub_host="127.0.0.1" ;;
  *)                      sub_host="$sub_listen" ;;
esac

# normalize path: must start and end with /
case "$sub_path" in
  /*) ;;
  *)  sub_path="/$sub_path" ;;
esac
case "$sub_path" in
  */) ;;
  *)  sub_path="$sub_path/" ;;
esac

log "subscription endpoint: http://${sub_host}:${sub_port}${sub_path}<sub_id>"

# ---- 4. collect client sub_ids --------------------------------------------
# new 3x-ui schema: clients table; old x-ui schema: client_traffics table;
# very old schema: subId lives inside inbounds.settings JSON.
rows="$(dbq "SELECT sub_id, email FROM clients WHERE enable IN (1,'1','true') AND sub_id IS NOT NULL AND trim(sub_id)<>''")"
[ -n "$rows" ] || rows="$(dbq "SELECT DISTINCT sub_id, email FROM client_traffics WHERE sub_id IS NOT NULL AND trim(sub_id)<>''")"
if [ -z "$rows" ]; then
  rows="$(dbq "SELECT settings FROM inbounds" \
    | grep -o '"subId"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -E 's/.*"subId"[[:space:]]*:[[:space:]]*"([^"]*)"/\1|\1/')"
fi
[ -n "$rows" ] || die "no clients with a subscription id found in the panel DB"

# ---- 5. fetch each client's links and filter xhttp + hy2 -------------------
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v base64 >/dev/null 2>&1 || die "base64 is required"

tmp="${OUT}.tmp.$$"
: > "$tmp"
total=0
clients=0

while IFS='|' read -r sid email; do
  [ -n "$sid" ] || continue
  url="http://${sub_host}:${sub_port}${sub_path}${sid}"
  body="$(curl -fsS --max-time 20 "$url" 2>/dev/null)" || {
    log "warn: no response for sub_id=$sid (${email:-no email}), skipped"
    continue
  }
  [ -n "$body" ] || continue

  # subscription body is base64-encoded link list; tolerate plain text too
  links="$(printf '%s\n' "$body" | tr -d '\r' | base64 -d 2>/dev/null || true)"
  case "$links" in
    *"://"* ) ;;
    *)        links="$body" ;;
  esac

  if [ "$KEEP_ALL" = "1" ]; then
    keep="$(printf '%s\n' "$links" | grep -E '^[a-zA-Z0-9+.-]+://' || true)"
  else
    keep="$(printf '%s\n' "$links" | grep -E '^(hysteria2?|hy2)://|^vless://.*type=xhttp' || true)"
  fi
  [ -n "$keep" ] || continue

  n="$(printf '%s\n' "$keep" | grep -c .)"
  {
    echo "########## ${email:-?} (sub_id: ${sid}) ##########"
    printf '%s\n' "$keep"
    echo
  } >> "$tmp"
  total=$((total + n))
  clients=$((clients + 1))
done <<EOF
$rows
EOF

[ "$total" -gt 0 ] || die "no xhttp/hy2 links received — check that such inbounds and enabled clients exist"

mv -f "$tmp" "$OUT"
log "done: $total link(s) from $clients client(s) -> $OUT"
