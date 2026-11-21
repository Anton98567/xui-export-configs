# xui-export-configs

Universal exporter of **XHTTP (VLESS) + Hysteria2** client configs from a local
**3x-ui / x-ui** panel into one file — one share link per line.

Works on any VPS with 3x-ui (or x-ui) installed: no IP, domain or password is
hardcoded. The script reads the panel SQLite DB only to find the built-in
subscription server settings, then pulls every client's links from it on
`127.0.0.1` — no panel login required. Link generation is done by the panel
itself, so the output is exactly what clients should import.

## Quick start (after 3x-ui install)

```bash
curl -fsSL https://raw.githubusercontent.com/Anton98567/xui-export-configs/main/xui-export.sh | bash
```

Result: `/root/all.txt` with all xhttp + hy2 links, grouped by client.

## What it does

1. Finds the panel DB (`/etc/x-ui/x-ui.db`, `/usr/local/x-ui/x-ui.db`,
   `/opt/x-ui/x-ui.db`, or `XUI_DB=/path/to/x-ui.db`).
2. Reads subscription settings (`subPort`, `subPath`, `subListen`, `subEnable`)
   and the list of client `sub_id`s (supports both new `clients` and old
   `client_traffics` schemas).
3. Fetches each client's subscription from the built-in sub server and decodes
   the base64 link list.
4. Filters links: `vless://...type=xhttp` and `hysteria2://` / `hy2://`
   (plus legacy `hysteria://`).
5. Writes everything to the output file, grouped by client.

## Usage

```bash
bash xui-export.sh
```

Environment variables:

| Variable   | Default         | Meaning                                          |
|------------|-----------------|--------------------------------------------------|
| `OUT`      | `/root/all.txt` | output file                                      |
| `KEEP_ALL` | `0`             | `1` = export every link, not only xhttp + hy2    |
| `XUI_DB`   | (auto-detect)   | explicit path to `x-ui.db`                       |

Examples:

```bash
# custom output file
OUT=/tmp/configs.txt bash xui-export.sh

# export ALL protocols (trojan, vmess, etc. too)
KEEP_ALL=1 bash xui-export.sh
```

## Example output

```text
########## user1 (sub_id: a1b2c3d4e5f6) ##########
vless://<uuid>@<host>:443?...&type=xhttp&...#VLESS%20xHTTP
hysteria2://<password>@<host>:443?...#Hysteria%202

########## user2 (sub_id: f6e5d4c3b2a1) ##########
...
```

## Requirements

- bash, curl, base64 (coreutils) — present on any Linux VPS;
- `sqlite3` **or** `python3` — to read the panel DB (python3 stdlib only);
- run on the VPS itself (it talks to the sub server on localhost);
- the built-in subscription server must be enabled in the panel
  (Settings -> Basic -> Subscription). It is enabled by default in 3x-ui.

## Notes

- Disabled clients are skipped; a client with no `sub_id` cannot be exported.
- The file contains raw share links (with secrets) — keep it private.
- Exit code is non-zero if nothing was exported.
