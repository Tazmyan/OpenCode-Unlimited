#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
ENTRY="$BIN_DIR/opencode-unlimited"
PLUGIN_SRC="$SCRIPT_DIR/plugins/unlimited-shield.js"
BRIDGE_SRC="$SCRIPT_DIR/lib/proxy-bridge.js"

USER_HOME="${HOME:-~}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$USER_HOME/.config}/opencode"
PLUGIN_DIR="$CONFIG_DIR/plugins"
PLUGIN_FOLDER="$PLUGIN_DIR/unlimited-shield"
PLUGIN_DST="$PLUGIN_FOLDER/index.js"

ok() { printf "  \033[32m[+]\033[0m %s\n" "$1"; }
bad() { printf "  \033[31m[x]\033[0m %s\n" "$1"; exit 1; }
info() { printf "      \033[90m%s\033[0m\n" "$1"; }

printf "==> opencode-unlimited install (macOS/Linux)\n"

# Verify build artifacts
for file in "$ENTRY" "$PLUGIN_SRC" "$BRIDGE_SRC"; do
  if [ ! -f "$file" ]; then
    bad "missing build artifact: $file"
  fi
done
ok "build artifacts present"

# Make CLI executable
chmod +x "$ENTRY"
ok "cli executable set"

# Check node
if command -v node >/dev/null 2>&1; then
  NODE_VER="$(node --version 2>/dev/null || true)"
  ok "node $NODE_VER"
else
  info "node not found: proxy bridge and -Db rotation stay unavailable"
fi

# Deploy plugin
mkdir -p "$PLUGIN_FOLDER"
cp -f "$PLUGIN_SRC" "$PLUGIN_DST"
ok "plugin deployed: $PLUGIN_DST"

# Configure PATH
NO_PATH=0
for arg in "$@"; do
  if [ "$arg" = "--no-path" ] || [ "$arg" = "-NoPath" ]; then
    NO_PATH=1
  fi
done

if [ "$NO_PATH" -eq 0 ]; then
  case ":$PATH:" in
    *":$BIN_DIR:"*)
      info "already on PATH: $BIN_DIR"
      ;;
    *)
      # Detect shell profile
      PROFILE=""
      if [ -n "$ZSH_VERSION" ] || [ "$(basename "$SHELL" 2>/dev/null || echo "")" = "zsh" ]; then
        PROFILE="$USER_HOME/.zshrc"
      elif [ -f "$USER_HOME/.bash_profile" ]; then
        PROFILE="$USER_HOME/.bash_profile"
      elif [ -f "$USER_HOME/.bashrc" ]; then
        PROFILE="$USER_HOME/.bashrc"
      else
        PROFILE="$USER_HOME/.profile"
      fi

      if [ -n "$PROFILE" ]; then
        if ! grep -q "$BIN_DIR" "$PROFILE" 2>/dev/null; then
          printf '\n# OpenCode-Unlimited\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$PROFILE"
          ok "added to PATH in $PROFILE: $BIN_DIR"
          info "open a new terminal or run 'source $PROFILE' to pick it up"
        else
          info "already configured in $PROFILE"
        fi
      fi

      # Also symlink to ~/.local/bin if directory exists
      if [ -d "$USER_HOME/.local/bin" ]; then
        ln -sf "$ENTRY" "$USER_HOME/.local/bin/opencode-unlimited" 2>/dev/null && ok "symlinked to $USER_HOME/.local/bin/opencode-unlimited" || true
      fi
      ;;
  esac
fi

# Run setup through CLI
"$ENTRY" install

printf "\n  \033[36mnext:\033[0m\n"
info "opencode-unlimited status     identity, plugin, network, bucket"
info "opencode-unlimited id         rotate the project id"
info "opencode-unlimited test       probe the bucket on this IP (free)"
info "opencode-unlimited proxy set socks5://127.0.0.1:1080   optional IP path"
printf "\n"
ok "installed"

