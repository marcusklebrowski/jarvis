#!/bin/bash
# jarvis-health.sh — quick loopback health probe for the J.A.R.V.I.S. server.
#
# Ports are read from server/config/server.yaml (falling back to
# server/config/server.example.yaml, then to built-in defaults) so this stays
# correct when the HUD TLS port or dashboard proxy port is reconfigured.
#
# A check is OK for any completed HTTP response (curl exit 0) and DOWN only on
# a connection failure or timeout.

ok(){ printf "%-22s %s\n" "$1" "$2"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"

# --- defaults (used if no config is readable) -------------------------------
WS_PORT=8765
TLS_PORTS="443 8766"
DASH_PROXY_PORT=9443
DASH_LO_HOST=127.0.0.1
DASH_LO_PORT=9119

# --- parse config via python3 ----------------------------------------------
# Emits shell-safe `NAME=value` lines for the keys it can resolve. Tries PyYAML
# first; if that import fails it falls back to a tiny indentation parser for the
# `server:` block; on any error it prints nothing and the defaults above stand.
CONFIG_VARS="$(
  CONFIG_DIR="$CONFIG_DIR" python3 - <<'PY' 2>/dev/null
import os, re, sys

cfg_dir = os.environ.get("CONFIG_DIR", ".")
path = None
for name in ("server.yaml", "server.example.yaml"):
    p = os.path.join(cfg_dir, name)
    if os.path.isfile(p) and os.access(p, os.R_OK):
        path = p
        break
if not path:
    sys.exit(0)

with open(path, "r", encoding="utf-8") as fh:
    text = fh.read()

server = None
try:
    import yaml
    data = yaml.safe_load(text) or {}
    server = data.get("server") or {}
except Exception:
    server = None

if server is None:
    # Minimal fallback parser: walk the `server:` block by indentation.
    server = {}
    dproxy = {}
    in_server = False
    in_dproxy = False
    dproxy_indent = 0
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        m = re.match(r"([\w.]+):\s*(.*)$", line.strip())
        if indent == 0:
            in_server = bool(m and m.group(1) == "server")
            in_dproxy = False
            continue
        if not in_server or not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if in_dproxy and indent <= dproxy_indent:
            in_dproxy = False
        if key == "dashboard_proxy" and not val:
            in_dproxy = True
            dproxy_indent = indent
            continue
        if in_dproxy:
            dproxy[key] = val
        else:
            server[key] = val
    if dproxy:
        server["dashboard_proxy"] = dproxy

def as_ports(v):
    if isinstance(v, (list, tuple)):
        return [str(int(x)) for x in v]
    return re.findall(r"\d+", str(v or ""))

out = []

ws = server.get("port")
if ws is not None and re.fullmatch(r"\d+", str(ws)):
    out.append("WS_PORT=%s" % ws)

tls = as_ports(server.get("tls_ports"))
if tls:
    out.append("TLS_PORTS=%s" % " ".join(tls))

dp = server.get("dashboard_proxy") or {}
if isinstance(dp, dict):
    dpp = dp.get("port")
    if dpp is not None and re.fullmatch(r"\d+", str(dpp)):
        out.append("DASH_PROXY_PORT=%s" % dpp)
    target = str(dp.get("target") or "")
    tm = re.search(r"https?://([A-Za-z0-9_.-]+)(?::(\d+))?", target)
    if tm:
        out.append("DASH_LO_HOST=%s" % tm.group(1))
        out.append("DASH_LO_PORT=%s" % (tm.group(2) or "80"))

print("\n".join(out))
PY
)"

while IFS= read -r line; do
    case "$line" in
        WS_PORT=[0-9]*)         WS_PORT="${line#WS_PORT=}" ;;
        TLS_PORTS=[0-9]*)       TLS_PORTS="${line#TLS_PORTS=}" ;;
        DASH_PROXY_PORT=[0-9]*) DASH_PROXY_PORT="${line#DASH_PROXY_PORT=}" ;;
        DASH_LO_HOST=?*)        DASH_LO_HOST="${line#DASH_LO_HOST=}" ;;
        DASH_LO_PORT=[0-9]*)    DASH_LO_PORT="${line#DASH_LO_PORT=}" ;;
    esac
done <<EOF
$CONFIG_VARS
EOF

# --- API key: try known locations, else probe unauthenticated --------------
KEY=""
for envfile in "$HOME/.hermes/.env" "$SCRIPT_DIR/../.env" "$HOME/jarvis/data/hermes/.env"; do
    if [ -f "$envfile" ]; then
        line="$(grep -E '^API_SERVER_KEY=' "$envfile" | head -n1)"
        if [ -n "$line" ]; then
            KEY="${line#API_SERVER_KEY=}"
            KEY="${KEY%\"}"; KEY="${KEY#\"}"
            KEY="${KEY%\'}"; KEY="${KEY#\'}"
            break
        fi
    fi
done

# --- checks ---------------------------------------------------------------
curl -s  -m 3 "http://127.0.0.1:${WS_PORT}/docs" -o /dev/null \
    && ok "voice ws (${WS_PORT})" OK || ok "voice ws (${WS_PORT})" DOWN

for p in $TLS_PORTS; do
    curl -sk -m 3 "https://127.0.0.1:${p}/hud/" -o /dev/null \
        && ok "HUD (${p})" OK || ok "HUD (${p})" DOWN
done

curl -s  -m 3 "http://${DASH_LO_HOST}:${DASH_LO_PORT}/" -o /dev/null \
    && ok "dashboard (${DASH_LO_PORT} lo)" OK || ok "dashboard (${DASH_LO_PORT} lo)" DOWN

curl -sk -m 3 "https://127.0.0.1:${DASH_PROXY_PORT}/" -o /dev/null \
    && ok "dash proxy (${DASH_PROXY_PORT})" OK || ok "dash proxy (${DASH_PROXY_PORT})" DOWN

if [ -n "$KEY" ]; then
    curl -s -m 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:8642/health | grep -q ok \
        && ok "hermes api (8642)" OK || ok "hermes api (8642)" DOWN
else
    curl -s -m 5 http://127.0.0.1:8642/health | grep -q ok \
        && ok "hermes api (8642)" OK || ok "hermes api (8642)" DOWN
fi
