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
#   PB_EXPIRE      expiration                (default: 1week)
#   PB_BURN        1 = burn after reading    (default: 0)
#   PB_VENV        venv location             (default: $HOME/.pbshare-venv)
#
# Output: the full share URL (including the #fragment) + the password.
# A public PrivateBin instance needs NO account. For full control, self-host
# PrivateBin (https://privatebin.info) and point PB_URL at it.

set -euo pipefail

FILE="${1:-${FILE:-/root/all.txt}}"
PB_URL="${PB_URL:-https://privatebin.net}"
PB_EXPIRE="${PB_EXPIRE:-1week}"
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

# verification: download and decrypt with the password, confirm it round-trips
verified = False
try:
    got = privatebinapi.get(url, password=password)
    verified = (got.get("text") == text)
except Exception:
    verified = False

print("URL=" + url)
print("PASSWORD=" + password)
print("EXPIRE=" + expire)
print("BURN=" + ("1" if burn else "0"))
print("VERIFIED=" + ("1" if verified else "0"))
PY
