#!/bin/sh
# Install separately downloaded TeamKit and Go KB macOS bundles without Go.
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <teamkit-bundle> <ci360-kb-bundle> [install-root]" >&2
  exit 2
fi

TEAMKIT_BUNDLE=$(cd "$1" && pwd)
KB_BUNDLE=$(cd "$2" && pwd)
ROOT=${3:-"$HOME/Documents/TeamKit"}
CLIENT=${TEAMKIT_INSTALL_CLIENT:-all}

case "$CLIENT" in
  claude|codex|copilot|zed|all) ;;
  *) echo "Unsupported TeamKit client: $CLIENT" >&2; exit 2 ;;
esac

case "$(uname -m)" in
  arm64) PLATFORM=darwin-arm64 ;;
  x86_64) PLATFORM=darwin-amd64 ;;
  *) echo "unsupported macOS architecture: $(uname -m)" >&2; exit 2 ;;
esac

teamkit_field() {
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$TEAMKIT_BUNDLE/RELEASE_MANIFEST.json" | head -n 1
}
kb_field() {
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$KB_BUNDLE/RELEASE_MANIFEST.json" | head -n 1
}

TEAMKIT_VERSION=$(teamkit_field version)
KB_VERSION=$(kb_field version)
[ "$(teamkit_field platform)" = "$PLATFORM" ] || { echo "TeamKit bundle platform mismatch" >&2; exit 2; }
[ "$(kb_field platform)" = "$PLATFORM" ] || { echo "CI360 KB bundle platform mismatch" >&2; exit 2; }
[ -n "$TEAMKIT_VERSION" ] && [ -n "$KB_VERSION" ] || { echo "bundle manifest has no version" >&2; exit 2; }

TEAMKIT_TARGET="$ROOT/releases/teamkit/$TEAMKIT_VERSION"
KB_ROOT="$ROOT/releases/ci360-kb-go"
KB_TARGET="$KB_ROOT/$KB_VERSION"

mkdir -p "$ROOT/releases/teamkit" "$KB_ROOT" "$ROOT/bin" "$ROOT/workspaces" "$ROOT/logs" "$ROOT/config"
GATEWAY_CONFIG="$ROOT/config/gateway.env"
gateway_value() {
  [ -f "$GATEWAY_CONFIG" ] || return 0
  sed -n "s/^$1=//p" "$GATEWAY_CONFIG" | head -n 1
}
GATEWAY_URL=$(gateway_value AZURE_APIM_GATEWAY_URL)
APIM_KEY=$(gateway_value ANTHROPIC_API_KEY_APIM)
USER_KEY=$(gateway_value CXAI_GATEWAY_USER_KEY)
if [ -z "$GATEWAY_URL" ]; then
  printf 'TeamKit setup (1 of 2)\nEnter your HTTPS APIM gateway URL: '
  IFS= read -r GATEWAY_URL
fi
case "$GATEWAY_URL" in
  https://*) ;;
  *) echo "The gateway URL must start with https://" >&2; exit 2 ;;
esac
case "$GATEWAY_URL" in
  *services.ai.azure.com*) echo "Use the TeamKit APIM gateway URL, not a direct Azure Foundry URL." >&2; exit 2 ;;
esac
case "$GATEWAY_URL" in
  */ai|*/ai/*|*/v1/messages) ;;
  *) echo "Use the TeamKit APIM /ai URL or an Anthropic /v1/messages URL." >&2; exit 2 ;;
esac
if [ -z "$APIM_KEY" ]; then
  printf 'TeamKit setup (2 of 2)\nEnter your APIM key (input is hidden): '
  trap 'stty echo 2>/dev/null || true' EXIT INT TERM
  stty -echo 2>/dev/null || true
  IFS= read -r APIM_KEY
  stty echo 2>/dev/null || true
  trap - EXIT INT TERM
  printf '\n'
fi
[ -n "$APIM_KEY" ] || { echo "An APIM key is required." >&2; exit 2; }
(umask 077; printf '%s\n' '# TeamKit Azure APIM gateway settings. Local only; never commit.' "AZURE_APIM_GATEWAY_URL=$GATEWAY_URL" "ANTHROPIC_API_KEY_APIM=$APIM_KEY" '# Optional when APIM does not inject the user identity.' "CXAI_GATEWAY_USER_KEY=$USER_KEY" > "$GATEWAY_CONFIG.new")
mv "$GATEWAY_CONFIG.new" "$GATEWAY_CONFIG"
export TEAMKIT_GATEWAY_CONFIG="$GATEWAY_CONFIG"
REAL_CLAUDE=${CLAUDE_BIN:-}
if [ -z "$REAL_CLAUDE" ]; then REAL_CLAUDE=$(command -v claude || true); fi
if [ "$REAL_CLAUDE" != "$ROOT/bin/claude" ] && [ -n "$REAL_CLAUDE" ] && [ -x "$REAL_CLAUDE" ]; then
  printf '%s\n' "$REAL_CLAUDE" > "$ROOT/config/claude-bin"
fi
TEAMKIT_STAGE=
TEAMKIT_INSTALL="$TEAMKIT_TARGET"
if [ ! -e "$TEAMKIT_TARGET" ]; then
  TEAMKIT_STAGE="$ROOT/releases/teamkit/.staging-$TEAMKIT_VERSION-$$"
  TEAMKIT_INSTALL="$TEAMKIT_STAGE"
  mkdir "$TEAMKIT_STAGE"
  cp -R "$TEAMKIT_BUNDLE"/. "$TEAMKIT_STAGE"/
fi

# ZIP extraction on another platform can lose executable permissions.
chmod 755 "$TEAMKIT_INSTALL/teamkit" "$TEAMKIT_INSTALL/teamkit-bin"
find "$TEAMKIT_INSTALL/packs" -type f -path '*/bin/*' -exec chmod 755 {} \;
if [ -e "$KB_TARGET" ]; then
  chmod 755 "$KB_TARGET/ci360-kb-go"
  "$KB_TARGET/ci360-kb-go" --doctor >/dev/null
else
  KB_STAGE="$KB_ROOT/.staging-$KB_VERSION-$$"
  mkdir "$KB_STAGE"
  cp -R "$KB_BUNDLE"/. "$KB_STAGE"/
  chmod 755 "$KB_STAGE/ci360-kb-go"
  "$KB_STAGE/ci360-kb-go" --doctor >/dev/null
fi
"$TEAMKIT_INSTALL/teamkit" policy verify >/dev/null

[ -z "$TEAMKIT_STAGE" ] || mv "$TEAMKIT_STAGE" "$TEAMKIT_TARGET"
if [ -n "${KB_STAGE:-}" ]; then
  mv "$KB_STAGE" "$KB_TARGET"
fi
printf '%s\n' "$KB_VERSION" > "$KB_ROOT/current.txt.new"
mv "$KB_ROOT/current.txt.new" "$KB_ROOT/current.txt"

WRAPPER="$ROOT/bin/teamkit"
printf '%s\n' '#!/bin/sh' 'set -eu' "export TEAMKIT_ROOT=\"$TEAMKIT_TARGET\"" "export TEAMKIT_PACK_ROOT=\"$TEAMKIT_TARGET/packs\"" "export TEAMKIT_GO_KB_RELEASE=\"$KB_TARGET\"" "export TEAMKIT_GATEWAY_CONFIG=\"$GATEWAY_CONFIG\"" "exec \"$TEAMKIT_TARGET/teamkit-bin\" \"\$@\"" > "$WRAPPER"
chmod 755 "$WRAPPER"
"$WRAPPER" provider claude-workspace-config --workspace "$ROOT/workspace" >/dev/null
"$WRAPPER" provider workspace-config --workspace "$ROOT/workspace" >/dev/null
LAUNCHER="$ROOT/Claude TeamKit.command"
printf '%s\n' '#!/bin/sh' 'set -eu' 'ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)' 'WORKSPACE="$ROOT/workspace"' 'if [ ! -f "$WORKSPACE/.mcp.json" ]; then "$ROOT/bin/teamkit" provider claude-workspace-config --workspace "$WORKSPACE"; fi' 'GATEWAY_CONFIG="$ROOT/config/gateway.env"' 'GATEWAY_URL=$(sed -n "s/^AZURE_APIM_GATEWAY_URL=//p" "$GATEWAY_CONFIG" | head -n 1)' 'APIM_KEY=$(sed -n "s/^ANTHROPIC_API_KEY_APIM=//p" "$GATEWAY_CONFIG" | head -n 1)' 'case "$GATEWAY_URL" in */v1/messages) GATEWAY_URL=${GATEWAY_URL%/v1/messages} ;; */ai/*) GATEWAY_URL=${GATEWAY_URL%%/ai/*}/ai ;; esac' 'export ANTHROPIC_BASE_URL="$GATEWAY_URL" ANTHROPIC_API_KEY="$APIM_KEY"' 'CLAUDE=${CLAUDE_BIN:-}' 'if [ -z "$CLAUDE" ] && [ -f "$ROOT/config/claude-bin" ]; then CLAUDE=$(cat "$ROOT/config/claude-bin"); fi' 'if [ -z "$CLAUDE" ] || [ ! -x "$CLAUDE" ]; then CLAUDE="$HOME/.local/bin/claude"; fi' 'if [ ! -x "$CLAUDE" ]; then echo "Claude Code is not installed. Install it, then run this file again."; exit 1; fi' 'cd "$WORKSPACE"' 'exec "$CLAUDE" --model haiku --mcp-config "$WORKSPACE/.mcp.json" "$@"' > "$LAUNCHER"
chmod 755 "$LAUNCHER"
TEAMKIT_CLAUDE="$ROOT/bin/teamkit-claude"
printf '%s\n' '#!/bin/sh' 'set -eu' 'ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)' 'exec "$ROOT/Claude TeamKit.command" "$@"' > "$TEAMKIT_CLAUDE"
chmod 755 "$TEAMKIT_CLAUDE"
# tk opens the saved default client. Neither this nor teamkit-claude is ever
# named "claude" -- that name must always resolve to the user's own Claude Code
# install, never a TeamKit shim. Use `tk --default <client>` to change it.
TK="$ROOT/bin/tk"
printf '%s\n' '#!/bin/sh' 'set -eu' 'ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)' 'DEFAULT_FILE="$ROOT/config/default-client"' 'if [ "${1:-}" = "--default" ]; then' '  CLIENT=${2:-}' '  if [ -z "$CLIENT" ] && [ -f "$DEFAULT_FILE" ]; then CLIENT=$(cat "$DEFAULT_FILE"); fi' '  case "$CLIENT" in claude|codex|copilot|zed) ;; *) echo "Usage: tk --default <claude|codex|copilot|zed>" >&2; exit 2 ;; esac' '  printf "%s\\n" "$CLIENT" > "$DEFAULT_FILE.new"' '  mv "$DEFAULT_FILE.new" "$DEFAULT_FILE"' '  echo "TeamKit default client: $CLIENT"' '  exit 0' 'fi' 'CLIENT=claude' 'if [ -f "$DEFAULT_FILE" ]; then CLIENT=$(cat "$DEFAULT_FILE"); fi' 'case "$CLIENT" in claude|codex|copilot|zed) exec "$ROOT/bin/teamkit-$CLIENT" "$@" ;; *) echo "TeamKit default client is invalid. Run: tk --default claude" >&2; exit 2 ;; esac' > "$TK"
chmod 755 "$TK"
CODEX_LAUNCHER="$ROOT/Codex TeamKit.command"
printf '%s\n' '#!/bin/sh' 'set -eu' 'ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)' 'WORKSPACE="$ROOT/workspace"' 'if [ ! -f "$WORKSPACE/AGENTS.md" ]; then "$ROOT/bin/teamkit" provider workspace-config --workspace "$WORKSPACE"; fi' 'if ! command -v codex >/dev/null 2>&1; then echo "Codex is not installed. Install it, then run this file again."; exit 1; fi' 'cd "$WORKSPACE"' 'exec codex "$@"' > "$CODEX_LAUNCHER"
chmod 755 "$CODEX_LAUNCHER"
TEAMKIT_CODEX="$ROOT/bin/teamkit-codex"
printf '%s\n' '#!/bin/sh' 'set -eu' 'ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)' 'exec "$ROOT/Codex TeamKit.command" "$@"' > "$TEAMKIT_CODEX"
chmod 755 "$TEAMKIT_CODEX"
COPILOT_LAUNCHER="$ROOT/Copilot TeamKit.command"
printf '%s\n' '#!/bin/sh' 'set -eu' 'ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)' 'WORKSPACE="$ROOT/workspace"' 'if [ ! -f "$WORKSPACE/.github/copilot-instructions.md" ]; then "$ROOT/bin/teamkit" provider workspace-config --workspace "$WORKSPACE"; fi' 'if ! command -v copilot >/dev/null 2>&1; then echo "GitHub Copilot CLI is not installed. Install it, then run this file again."; exit 1; fi' 'cd "$WORKSPACE"' 'exec copilot "$@"' > "$COPILOT_LAUNCHER"
chmod 755 "$COPILOT_LAUNCHER"
TEAMKIT_COPILOT="$ROOT/bin/teamkit-copilot"
printf '%s\n' '#!/bin/sh' 'set -eu' 'ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)' 'exec "$ROOT/Copilot TeamKit.command" "$@"' > "$TEAMKIT_COPILOT"
chmod 755 "$TEAMKIT_COPILOT"
ZED_LAUNCHER="$ROOT/Zed TeamKit.command"
printf '%s\n' '#!/bin/sh' 'set -eu' 'ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)' 'WORKSPACE="$ROOT/workspace"' 'if [ ! -f "$WORKSPACE/.rules" ]; then "$ROOT/bin/teamkit" provider workspace-config --workspace "$WORKSPACE"; fi' 'if ! command -v zed >/dev/null 2>&1; then echo "Zed is not installed. Install it, then run this file again."; exit 1; fi' 'exec zed "$WORKSPACE" "$@"' > "$ZED_LAUNCHER"
chmod 755 "$ZED_LAUNCHER"
TEAMKIT_ZED="$ROOT/bin/teamkit-zed"
printf '%s\n' '#!/bin/sh' 'set -eu' 'ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)' 'exec "$ROOT/Zed TeamKit.command" "$@"' > "$TEAMKIT_ZED"
chmod 755 "$TEAMKIT_ZED"
DEFAULT_CLIENT=$CLIENT
[ "$DEFAULT_CLIENT" = all ] && DEFAULT_CLIENT=claude
printf '%s\n' "$DEFAULT_CLIENT" > "$ROOT/config/default-client.new"
mv "$ROOT/config/default-client.new" "$ROOT/config/default-client"
# Remove the legacy shim if this is an upgrade. It shadowed the user's normal Claude command.
rm -f "$ROOT/bin/claude"
ZSHRC="$HOME/.zshrc"
if [ -f "$ZSHRC" ]; then
  awk '
    /^# >>> TeamKit Claude >>>$/ { skip=1; next }
    /^# <<< TeamKit Claude <<<$/{ skip=0; next }
    !skip { print }
  ' "$ZSHRC" > "$ZSHRC.teamkit-next"
  mv "$ZSHRC.teamkit-next" "$ZSHRC"
fi
# Only put TeamKit's bin/ on PATH once it's confirmed clean of a claude shim --
# never let a stray/partial install shadow the user's real claude command.
if [ ! -e "$ROOT/bin/claude" ] && ! grep -Fqx '# >>> TeamKit commands >>>' "$ZSHRC" 2>/dev/null; then
  printf '\n%s\nexport PATH="%s/bin:$PATH"\n%s\n' '# >>> TeamKit commands >>>' "$ROOT" '# <<< TeamKit commands <<<' >> "$ZSHRC"
fi
"$WRAPPER" kb >/dev/null
GATEWAY_STATUS=$("$WRAPPER" gateway status)
printf '%s\n' "$GATEWAY_STATUS" | grep -q '"ready":true' || { echo "Gateway setup is incomplete; check the URL and APIM key." >&2; exit 1; }
"$WRAPPER" route '-ask What is MAI?' >/dev/null
echo "TeamKit $TEAMKIT_VERSION is ready. Default client: $DEFAULT_CLIENT. Open a new Terminal and run: tk"
