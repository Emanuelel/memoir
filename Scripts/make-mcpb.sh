#!/usr/bin/env bash
#
# Memoir: build dist/memoir.mcpb, the one-click MCP install bundle for Claude Desktop.
#
# An .mcpb (formerly .dxt; both extensions still install) is a ZIP with a manifest.json at
# its root. Spec: https://github.com/modelcontextprotocol/mcpb/blob/main/MANIFEST.md
#
# THIS BUNDLE IS A POINTER, NOT A COPY
# ====================================
# The usual .mcpb embeds the server it runs. Memoir's does not, and that is a decision worth
# stating: memoir-mcp is only useful beside the database the app writes, and the app already
# puts it at a known absolute path. Embedding a second copy would mean a user could install a
# 0.1.0 server against a 0.3.0 database and get answers from a schema that no longer exists.
# So the manifest points `command` at the installed binary, the bundle stays a few kilobytes,
# and the server can never be a different build from the app that fills its database.
#
# The cost, paid honestly: Memoir.app must be installed first. This script refuses to build a
# manifest pointing somewhere that does not exist unless you insist (see --allow-missing).
#
# THE SHAPE WAS VERIFIED, NOT GUESSED
# ===================================
# `mcp_config` nests INSIDE `server`, and `server` requires all three of `type`,
# `entry_point` and `mcp_config` (checked against the machine-readable schema, not the prose):
#   schemas/mcpb-manifest-v0.3.schema.json in modelcontextprotocol/mcpb
#     server.required          = ["type", "entry_point", "mcp_config"]
#     mcp_config.required      = ["command"]
#     additionalProperties     = false, at the top level and inside server
# That last line is why this script validates before zipping: a stray key is not ignored, it
# is invalid, and an invalid manifest fails at install time in someone else's app with no
# useful message. Cheap to check here, expensive to discover there.
#
#   Scripts/make-mcpb.sh                  build dist/memoir.mcpb
#   Scripts/make-mcpb.sh --allow-missing  build even if Memoir.app is not installed
#
# Environment, all optional:
#   MEMOIR_MCP_PATH   the binary the manifest runs.
#                     Default /Applications/Memoir.app/Contents/MacOS/memoir-mcp
#   MEMOIR_AUTHOR     who the install card credits. Default "Memoir". Set a person or a
#                     company rather than editing this file.
#   MEMOIR_LICENSE    SPDX identifier. ABSENT BY DEFAULT and meant to stay that way until a
#                     LICENSE file exists: a licence is a grant the author makes, and a build
#                     script that invents one publishes rights nobody granted.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
cd "$ROOT"

if [[ ! -f "$ROOT/Scripts/version.sh" ]]; then
    echo "make-mcpb.sh: Scripts/version.sh is missing. It holds the version number" >&2
    exit 2
fi
# shellcheck source=version.sh
. "$ROOT/Scripts/version.sh"

# The path the manifest will tell Claude Desktop to run. Overridable so a user who keeps apps
# somewhere other than /Applications can still build a bundle that works for them.
MCP_PATH="${MEMOIR_MCP_PATH:-/Applications/Memoir.app/Contents/MacOS/memoir-mcp}"

# Who the install card credits. Defaults to the product name because the repo does not say
# who wrote it; set MEMOIR_AUTHOR to a person or a company rather than editing this script.
AUTHOR_NAME="${MEMOIR_AUTHOR:-Memoir}"

# The licence is OPTIONAL in the schema and absent here by default, deliberately.
#
# This field once read "MIT". Nothing in this repository says that: there is no LICENSE file,
# no COPYING file, and no licence statement in any of the docs. A licence is a legal grant the
# author makes, not a detail a build script can infer. This one would have been published
# inside a bundle built for distribution, telling every recipient they had rights the author
# never granted. Omitting the field says "unstated", which is true. Guessing says something
# false in the one direction that is hard to take back.
#
# Once a LICENSE file exists and says what it says, set MEMOIR_LICENSE to the matching SPDX
# identifier (MIT, Apache-2.0, …) and the field appears.
LICENSE_ID="${MEMOIR_LICENSE:-}"

# Both of the above land inside a JSON string literal. A stray quote or backslash would turn
# the manifest into not-JSON; the validator below would catch it, but failing at the point of
# the mistake beats failing three steps later.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # backslashes first: the other order double-escapes the quotes
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

DIST="$ROOT/dist"
OUT="$DIST/memoir.mcpb"
STAGE="$DIST/mcpb-stage"

ALLOW_MISSING=0
for arg in "$@"; do
    case "$arg" in
        --allow-missing) ALLOW_MISSING=1 ;;
        -h|--help) sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'; exit 0 ;;
        *) echo "make-mcpb.sh: unknown option '$arg' (want --allow-missing or --help)" >&2; exit 2 ;;
    esac
done

echo "==> Bundle target"
echo "    version: $MEMOIR_VERSION"
echo "    command: $MCP_PATH"

if [[ ! -x "$MCP_PATH" ]]; then
    if [[ $ALLOW_MISSING -eq 1 ]]; then
        echo "    WARNING: nothing executable there. Building anyway (--allow-missing)."
        echo "             The bundle will install and then fail to start until Memoir.app exists."
    else
        cat >&2 <<EOF

make-mcpb.sh: no executable at
  $MCP_PATH

This manifest references the installed binary rather than embedding a copy, so building one
that points at nothing produces a bundle that installs cleanly and then fails to start: the
worst of both outcomes, because the error surfaces inside Claude Desktop rather than here.

Fix one of these:
  bash Scripts/deploy.sh                    build and install to /Applications
  MEMOIR_MCP_PATH=/path/to/memoir-mcp ...   point at another install
  bash Scripts/make-mcpb.sh --allow-missing build anyway, on purpose
EOF
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# The tool list
#
# manifest.tools is optional and purely descriptive: it is what the install card shows
# before anyone connects. Hardcoding the twelve names here would create a second source of
# truth that drifts the first time a tool is added, and drifts silently, because nothing
# validates the list against the server.
#
# So ask the server. This is the same handshake verify.sh stage 7 runs, against a throwaway
# database so it never touches the user's real one.
# ─────────────────────────────────────────────────────────────────────────────
TOOLS_JSON=""
probe_tools() {
    local bin=""
    local c
    for c in "$ROOT/build/Memoir.app/Contents/MacOS/memoir-mcp" \
             "$MCP_PATH" \
             "$ROOT/.build/release/memoir-mcp" \
             "$ROOT/.build/debug/memoir-mcp"; do
        if [[ -x "$c" ]]; then bin="$c"; break; fi
    done
    [[ -n "$bin" ]] || { echo "    no memoir-mcp to ask; omitting the tools list"; return 0; }
    command -v python3 >/dev/null 2>&1 || { echo "    no python3; omitting the tools list"; return 0; }

    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/memoir-mcpb.XXXXXX")"
    local out="$tmp/stdout"
    # alarm(2) survives exec, and exec resets SIGALRM to its default action, so a server that
    # wedges on the handshake cannot wedge the release build behind it.
    printf '%s\n%s\n%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"make-mcpb.sh","version":"1"}}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
        | perl -e 'alarm 60; exec { $ARGV[0] } @ARGV;' \
            "$bin" --db "$tmp/probe.sqlite" > "$out" 2>/dev/null || true

    # The schema allows exactly `name` and `description` per tool and nothing else
    # (additionalProperties: false), so inputSchema is dropped rather than passed through.
    TOOLS_JSON="$(python3 - "$out" <<'PY' || true
import json, sys
tools = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        frame = json.loads(line)
    except ValueError:
        continue
    if isinstance(frame, dict) and frame.get("id") == 2:
        for t in frame.get("result", {}).get("tools", []) or []:
            name = t.get("name")
            if not name:
                continue
            entry = {"name": name}
            desc = t.get("description")
            if desc:
                # One line: this is a card subtitle, not documentation.
                entry["description"] = " ".join(str(desc).split())
            tools.append(entry)
if tools:
    sys.stdout.write(json.dumps(tools, indent=2))
PY
)"
    rm -rf "$tmp"
    if [[ -n "$TOOLS_JSON" ]]; then
        echo "    tools: $(printf '%s' "$TOOLS_JSON" | grep -c '"name"') from ${bin#$ROOT/}"
    else
        echo "    the server answered nothing usable; omitting the tools list"
    fi
}

echo "==> Asking memoir-mcp for its tool list"
probe_tools

# ─────────────────────────────────────────────────────────────────────────────
# The manifest
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Writing manifest.json"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# The only interpolated value that did not originate in this script is $TOOLS_JSON, and that
# arrives already JSON-encoded by python3's json.dumps. Tool descriptions are the one place
# a quote or a newline could come from the server and turn the manifest into not-JSON.
# Everything else below is a literal this script owns.
write_manifest() {
    local license_block=""
    if [[ -n "$LICENSE_ID" ]]; then
        license_block="  \"license\": \"$(json_escape "$LICENSE_ID")\",
"
    fi

    local tools_block=""
    if [[ -n "$TOOLS_JSON" ]]; then
        # Indent the block to sit at one level inside the object, and comma-terminate it.
        tools_block="  \"tools\": $(printf '%s' "$TOOLS_JSON" | sed '2,$s/^/  /'),
  \"tools_generated\": false,
"
    fi
    cat > "$STAGE/manifest.json" <<MANIFEST
{
  "manifest_version": "0.3",
  "name": "memoir",
  "display_name": "Memoir",
  "version": "$MEMOIR_VERSION",
  "description": "Read your local Memoir work memory: what you did, who came up, what you owe, and where the time went. Every answer carries its provenance.",
  "long_description": "Memoir builds a local memory of your working day from the text your apps publish to macOS for screen readers, and keeps it in one SQLite file on your Mac. This bundle connects that memory to Claude Desktop read-only: nothing it exposes can write to the database, and \`propose_memory\` only stages a suggestion for you to accept or reject yourself.\n\nRequires Memoir.app to be installed: this bundle runs the server already inside it rather than shipping a second copy, so the server can never be a different build from the app that fills its database.",
  "author": {
    "name": "$(json_escape "$AUTHOR_NAME")"
  },
  "keywords": ["memory", "productivity", "macos", "local-first", "privacy"],
$license_block$tools_block  "server": {
    "type": "binary",
    "entry_point": "$MCP_PATH",
    "mcp_config": {
      "command": "$MCP_PATH",
      "args": [],
      "env": {}
    }
  },
  "compatibility": {
    "platforms": ["darwin"]
  }
}
MANIFEST
}
write_manifest

# ─────────────────────────────────────────────────────────────────────────────
# Validate before zipping
#
# The manifest is the whole bundle. If it is malformed the failure lands in Claude Desktop,
# with no line number and no build log. So everything checkable is checked here.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Validating"
if command -v python3 >/dev/null 2>&1; then
    python3 - "$STAGE/manifest.json" <<'PY'
import json, sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        m = json.load(fh)
except ValueError as e:
    print("manifest.json is not valid JSON: %s" % e)
    sys.exit(1)

def die(msg):
    print("manifest.json: " + msg)
    sys.exit(1)

# Mirrors mcpb-manifest-v0.3.schema.json. Kept as an explicit list rather than a fetched
# schema so the release path never depends on the network being up.
TOP_REQUIRED = ["name", "version", "description", "author", "server"]
TOP_ALLOWED = {
    "$schema", "_meta", "author", "compatibility", "description", "display_name",
    "documentation", "dxt_version", "homepage", "icon", "icons", "keywords", "license",
    "localization", "long_description", "manifest_version", "name", "privacy_policies",
    "prompts", "prompts_generated", "repository", "screenshots", "server", "support",
    "tools", "tools_generated", "user_config", "version",
}

for k in TOP_REQUIRED:
    if k not in m:
        die("missing required top-level field %r" % k)
stray = sorted(set(m) - TOP_ALLOWED)
if stray:
    die("unknown top-level field(s) %s; the schema sets additionalProperties: false" % stray)
if m.get("manifest_version") != "0.3":
    die("manifest_version is %r, the schema pins it to '0.3'" % m.get("manifest_version"))
if not isinstance(m.get("author"), dict) or not m["author"].get("name"):
    die("author.name is required")

server = m["server"]
if not isinstance(server, dict):
    die("server must be an object")
for k in ("type", "entry_point", "mcp_config"):
    if k not in server:
        die("server.%s is required by the schema (this is the field the shape is easy to get "
            "wrong on: mcp_config nests INSIDE server)" % k)
stray = sorted(set(server) - {"type", "entry_point", "mcp_config"})
if stray:
    die("unknown server field(s) %s" % stray)
if server["type"] not in ("python", "node", "binary"):
    die("server.type is %r, must be one of python/node/binary" % server["type"])

cfg = server["mcp_config"]
if not isinstance(cfg, dict) or not cfg.get("command"):
    die("server.mcp_config.command is required")
stray = sorted(set(cfg) - {"command", "args", "env", "platform_overrides"})
if stray:
    die("unknown mcp_config field(s) %s" % stray)

for t in m.get("tools", []):
    if not t.get("name"):
        die("a tools[] entry has no name")
    stray = sorted(set(t) - {"name", "description"})
    if stray:
        die("tools[%r] has unknown field(s) %s" % (t.get("name"), stray))

print("  ok  manifest_version %s, %s, %d tool(s)"
      % (m["manifest_version"], m["server"]["type"], len(m.get("tools", []))))
print("  ok  server.mcp_config.command = %s" % cfg["command"])
PY
else
    # No python3: at least prove it parses. plutil reads JSON.
    echo "  (python3 unavailable: syntax check only)"
    plutil -lint "$STAGE/manifest.json" >/dev/null || {
        echo "manifest.json is not valid JSON" >&2; exit 1; }
    echo "  ok  parses as JSON"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Zip it
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Packing $OUT"
rm -f "$OUT"
# ditto rather than zip: it ships with macOS, and without --keepParent it puts the staging
# directory's *contents* at the archive root, which is where manifest.json has to be. A zip
# with the manifest one directory down is not an .mcpb, it is a file that fails to install.
# --norsrc --noextattr keeps __MACOSX/ and xattr noise out of a bundle other people unpack.
ditto -c -k --norsrc --noextattr "$STAGE" "$OUT"
rm -rf "$STAGE"

# Prove the manifest really did land at the root, rather than trusting the flag.
if ! unzip -l "$OUT" 2>/dev/null | grep -qE '[[:space:]]manifest\.json$'; then
    echo "make-mcpb.sh: manifest.json is not at the root of $OUT" >&2
    unzip -l "$OUT" >&2 || true
    exit 1
fi

echo "==> Built"
echo "    $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
unzip -l "$OUT" | sed 's/^/    /'
cat <<EOF

Install: double-click $(basename "$OUT"), or drag it onto Claude Desktop's
         Settings > Extensions pane.

It runs the server inside the installed app:
    $MCP_PATH
EOF
