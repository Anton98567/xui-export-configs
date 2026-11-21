#!/usr/bin/env bash
#
# pb-share.sh — upload a file to a PrivateBin instance as a PASSWORD-PROTECTED,
# PLAIN-TEXT paste and print the share link + password.
#
# Why PrivateBin: unlike pastebin.com (whose API has no password parameter at
# all), PrivateBin gives a real password-gated link where the recipient opens
# the URL, types the password, and reads the file as ordinary text. Content is
# encrypted in the browser (AES-256-GCM) and the password is a second layer on
# top of the link, so neither the link alone nor the password alone is enough.
#
# Usage:
#   bash pb-share.sh [FILE]
#
# Environment:
#   FILE           file to upload            (default: /root/all.txt, or $1)
#   PB_URL         PrivateBin instance       (default: https://privatebin.net)
#   PB_PASSWORD    password                  (default: auto-generated, 20 chars)
#   PB_EXPIRE      expiration                (default: 3day)
#   PB_BURN        1 = burn after reading    (default: 0)
#   PB_VENV        venv location             (default: $HOME/.pbshare-venv)
#
# Output: the full share URL (including the #fragment) + the password + the
# ACTUAL storage time (how long the paste lives before it is deleted).
#
# NOTE on expiration: each PrivateBin instance only accepts specific values.
# https://privatebin.net supports: 5min, 10min, 30min, 3hour, 6hour, 12hour,
# 1day, 3day (max 3 days). If you pass a value the instance does not know, it
# silently falls back to a short default (e.g. 1 hour) — so the script verifies
# and prints the real TTL it got back. For longer storage use your own instance
# (self-host PrivateBin) or pick a host with a longer maximum.
#
# A public PrivateBin instance needs NO account. For full control, self-host
# PrivateBin (https://privatebin.info) and point PB_URL at it.

set -euo pipefail

FILE="${1:-${FILE:-/root/all.txt}}"
PB_URL="${PB_URL:-https://privatebin.net}"
PB_EXPIRE="${PB_EXPIRE:-3day}"
PB_BURN="${PB_BURN:-0}"
PB_PASS="${PB_PASSWORD:-}"
VENV="${PB_VENV:-$HOME/.pbshare-venv}"

log() { echo "[pb-share] $*"; }
die() { echo "[pb-share] ERROR: $*" >&2; exit 1; }

[ -f "$FILE" ]  || die "file not found: $FILE"
[ -s "$FILE" ]  || die "file is empty: $FILE"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# ---- bootstrap: venv + privatebinapi --------------------------------------
if [ ! -x "$VENV/bin/python" ]; then
  log "creating venv at $VENV"
  python3 -m venv "$VENV" >/dev/null 2>&1 || die "could not create venv (is python3-venv installed?)"
fi
if ! "$VENV/bin/python" -c "import privatebinapi" >/dev/null 2>&1; then
  log "installing privatebinapi (first run only)"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check \
      privatebinapi cryptography >/dev/null 2>&1 \
    || die "failed to install privatebinapi (need internet + pip)"
fi

# ---- upload + verify ------------------------------------------------------
export FILE PB_URL PB_EXPIRE PB_BURN PB_PASS
"$VENV/bin/python" - <<'PY'
import os, sys, secrets, string
import privatebinapi
import privatebinapi.upload as _up

# The privatebinapi library validates expiration against a hardcoded list that
# does NOT know instance-specific values like "3day" (the 3-day maximum on
# privatebin.net). pbincli passes meta.expire to the server verbatim, so we can
# safely widen the allow-list and send whatever the instance supports.
_up.EXPIRATION_TIMES = (
    "5min", "10min", "30min", "1hour", "3hour", "6hour", "12hour",
    "1day", "2day", "3day", "1week", "2week", "1month", "3month",
    "6month", "1year", "never",
)

file_path = os.environ["FILE"]
pb_url    = os.environ["PB_URL"]
expire    = os.environ["PB_EXPIRE"]
burn      = os.environ["PB_BURN"] == "1"
password  = os.environ.get("PB_PASS", "").strip()

with open(file_path, "r", encoding="utf-8", errors="replace") as f:
    text = f.read()
if not text.strip():
    sys.exit("ERROR: file has no content")

if not password:
    alphabet = string.ascii_letters + string.digits
    password = "".join(secrets.choice(alphabet) for _ in range(20))

def attempt(burn_flag):
    return privatebinapi.send(
        pb_url,
        text=text,
        password=password,
        formatting="plaintext",
        expiration=expire,
        burn_after_reading=burn_flag,
    )

try:
    resp = attempt(burn)
except Exception:
    if burn:
        # some instances disallow burn+password combos; retry without burn
        resp = attempt(False)
        burn = False
    else:
        raise

url = resp["full_url"]

# verification: download and decrypt with the password, confirm it round-trips,
# and read the REAL time-to-live the instance assigned (not what we requested).
verified = False
ttl = None
try:
    got = privatebinapi.get(url, password=password)
    verified = (got.get("text") == text)
    ttl = got.get("meta", {}).get("time_to_live")
except Exception:
    verified = False

def human(sec):
    sec = int(sec)
    d, r = divmod(sec, 86400)
    h, r = divmod(r, 3600)
    m, s = divmod(r, 60)
    out = []
    if d: out.append(f"{d}d")
    if h: out.append(f"{h}h")
    if m: out.append(f"{m}m")
    if not out: out.append(f"{s}s")
    return " ".join(out)

print("URL=" + url)
print("PASSWORD=" + password)
print("EXPIRE_REQUESTED=" + expire)
print("TTL_SECONDS=" + (str(ttl) if ttl is not None else "unknown"))
print("TTL_HUMAN=" + (human(ttl) if ttl is not None else "unknown"))
print("BURN=" + ("1" if burn else "0"))
print("VERIFIED=" + ("1" if verified else "0"))

# Guard against silent downgrades: if the instance gave us a much shorter life
# than the value we asked for (e.g. asked "3day", got ~1 hour), say so loudly.
_want = {
    "5min": 300, "10min": 600, "30min": 1800, "1hour": 3600, "3hour": 10800,
    "6hour": 21600, "12hour": 43200, "1day": 86400, "2day": 172800,
    "3day": 259200, "1week": 604800, "1month": 2592000, "1year": 31536000,
}
if ttl is not None and expire in _want and int(ttl) < _want[expire] * 0.5:
    print("WARN=instance capped the expiration: requested %s but got %s (use an instance that allows longer, or self-host)"
          % (expire, human(ttl)))
PY
