#!/usr/bin/env bash
#
# xui-pastebin-upload.sh — upload a file (default: /root/all.txt) to pastebin.com
# as a PASSWORD-PROTECTED paste.
#
# Pastebin's API cannot create natively password-protected pastes (that is a
# web/Pro feature), so this script encrypts the content first
# (AES-256-CBC + PBKDF2-SHA256 via openssl) and uploads the ciphertext as an
# UNLISTED paste. Without the password the paste content is unreadable —
# there is no public access to the configs.
#
# Usage:
#   PASTEBIN_DEV_KEY=<your dev key> bash xui-pastebin-upload.sh
#   (or store the key in /root/.pastebin_key, chmod 600)
#
# Environment:
#   FILE              file to upload              (default: /root/all.txt)
#   PASS              password                    (default: random, auto-generated)
#   NAME              paste title                 (default: encrypted-configs)
#   EXPIRE            N|10M|1H|1D|1W|2W|1M|6M|1Y  (default: N = never)
#   PASTEBIN_DEV_KEY  API dev key from https://pastebin.com/doc_api
#
# Output: paste URL + password + ready-to-use decrypt command.

set -u

FILE="${FILE:-/root/all.txt}"
NAME="${NAME:-encrypted-configs}"
EXPIRE="${EXPIRE:-N}"

log() { echo "[xui-pastebin] $*"; }
die() { echo "[xui-pastebin] ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1    || die "curl is required"
command -v openssl >/dev/null 2>&1 || die "openssl is required"
command -v base64 >/dev/null 2>&1  || die "base64 is required"

[ -s "$FILE" ] || die "file not found or empty: $FILE"

# ---- API key: env PASTEBIN_DEV_KEY or /root/.pastebin_key -----------------
KEY="${PASTEBIN_DEV_KEY:-}"
if [ -z "$KEY" ] && [ -f /root/.pastebin_key ]; then
  KEY="$(tr -d '[:space:]' < /root/.pastebin_key)"
fi
[ -n "$KEY" ] || die "no API key. Set PASTEBIN_DEV_KEY=<key> or put the key into /root/.pastebin_key (chmod 600)"

# ---- password (random unless PASS is set) ---------------------------------
if [ -z "${PASS:-}" ]; then
  PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
fi
[ -n "$PASS" ] || die "failed to generate a password; set PASS env"

# ---- encrypt the content --------------------------------------------------
tmp_bin="$(mktemp /tmp/xui-paste-XXXXXX.bin)"
tmp_txt="$(mktemp /tmp/xui-paste-XXXXXX.txt)"
trap 'rm -f "$tmp_bin" "$tmp_txt"' EXIT

PW="$PASS" openssl enc -aes-256-cbc -pbkdf2 -md sha256 -salt \
  -pass env:PW -in "$FILE" -out "$tmp_bin" 2>/dev/null \
  || die "openssl encryption failed (need OpenSSL 1.1.1+ with -pbkdf2)"

blob="$(base64 < "$tmp_bin" | tr -d '\n')"

cat > "$tmp_txt" <<EOF
# encrypted-configs: AES-256-CBC + PBKDF2-SHA256 ciphertext (password protected)
# The password is shared separately and is NOT part of this paste.
# Decrypt:
#   base64 -d file.enc.b64 | openssl enc -aes-256-cbc -pbkdf2 -md sha256 -d -pass pass:'<PASSWORD>' -out all.txt
# (save the line below as file.enc.b64 first, or pipe it straight into base64 -d)
$blob
EOF

# ---- upload (unlisted paste) ---------------------------------------------
resp="$(curl -fsS --max-time 60 https://pastebin.com/api/api_post.php \
  --data-urlencode "api_dev_key=$KEY" \
  --data-urlencode "api_option=paste" \
  --data-urlencode "api_paste_code@$tmp_txt" \
  --data-urlencode "api_paste_name=$NAME" \
  --data-urlencode "api_paste_private=1" \
  --data-urlencode "api_paste_expire_date=$EXPIRE" \
  --data-urlencode "api_paste_format=text" 2>&1)" || true

case "$resp" in
  https://pastebin.com/*) url="$resp" ;;
  *) die "pastebin API error: $resp" ;;
esac

pid="${url##*/}"
raw="https://pastebin.com/raw/$pid"

# ---- best-effort verification: download back and decrypt ------------------
if back="$(curl -fsS --max-time 60 "$raw" 2>/dev/null)"; then
  if printf '%s\n' "$back" | tail -n1 | base64 -d 2>/dev/null \
     | PW="$PASS" openssl enc -aes-256-cbc -pbkdf2 -md sha256 -d -pass env:PW 2>/dev/null \
     | cmp -s - "$FILE"; then
    log "verified: remote copy decrypts back to the original file"
  else
    log "warn: could not verify the remote copy yet (paste may need a moment to propagate)"
  fi
else
  log "warn: could not fetch $raw for verification"
fi

echo
log "URL:      $url"
log "PASSWORD: $PASS"
log "decrypt:  curl -s $raw | base64 -d | openssl enc -aes-256-cbc -pbkdf2 -md sha256 -d -pass pass:'$PASS' -out all.txt"
