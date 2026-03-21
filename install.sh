#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Chasm installer
#   ./install.sh            — installs to ~/.local/bin  (default)
#   ./install.sh /usr/local — installs to /usr/local/bin
# ---------------------------------------------------------------------------

PREFIX="${1:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Pre-self-hosting (< v0.2.0):
#   This script built the Chasm compiler from Zig source using `zig build`.
#
# Post-self-hosting (>= v0.2.0):
#   The Zig compiler is archived in archive/zig-compiler/ and frozen.
#   The bootstrap binary is pre-built and lives in bootstrap/bin/.
#   This script installs the pre-built binary directly — no Zig required.
#
#   Once the self-hosted compiler (compiler/*.chasm) is complete, this
#   script will be updated to build from Chasm source instead.
# ---------------------------------------------------------------------------

echo "Installing to $BIN_DIR..."
mkdir -p "$BIN_DIR"

# Build the Go CLI driver.
if ! command -v go &>/dev/null; then
    echo "ERROR: 'go' not found in PATH."
    echo "Install Go from https://go.dev/dl/ then re-run this script."
    exit 1
fi

echo "building chasm CLI..."
go build -o "$BIN_DIR/chasm" "$SCRIPT_DIR/cmd/chasm/"

echo ""
echo "Installed:"
echo "  $BIN_DIR/chasm"
echo ""
echo "Set CHASM_HOME if the repo is not auto-detected:"
echo "  export CHASM_HOME=\"$SCRIPT_DIR\""

# Check if BIN_DIR is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo ""
    echo "  NOTE: $BIN_DIR is not in your PATH."
    echo ""

    SHELL_NAME="$(basename "${SHELL:-bash}")"
    case "$SHELL_NAME" in
        zsh)  RC="$HOME/.zshrc" ;;
        fish) RC="$HOME/.config/fish/config.fish" ;;
        *)    RC="$HOME/.bashrc" ;;
    esac

    echo "  Add it by running:"
    echo ""
    if [[ "$SHELL_NAME" == "fish" ]]; then
        echo "    echo 'fish_add_path $BIN_DIR' >> $RC"
    else
        echo "    echo 'export PATH=\"\$PATH:$BIN_DIR\"' >> $RC"
    fi
    echo "    source $RC"
    echo ""
    echo "  Or for this session only:"
    echo "    export PATH=\"\$PATH:$BIN_DIR\""
fi

echo ""

# ---- Editor extensions -----------------------------------------------------
EXT_SRC="$SCRIPT_DIR/editors/vscode"
EXT_NAME="chasm.chasm-language-0.1.0"

install_extension() {
    local ext_dir="$1"
    local reg="$2"
    if [[ ! -d "$ext_dir" ]]; then return; fi

    mkdir -p "$ext_dir/$EXT_NAME/syntaxes"
    cp "$EXT_SRC/package.json"                          "$ext_dir/$EXT_NAME/package.json"
    cp "$EXT_SRC/language-configuration.json"           "$ext_dir/$EXT_NAME/language-configuration.json"
    cp "$EXT_SRC/syntaxes/chasm.tmLanguage.json"        "$ext_dir/$EXT_NAME/syntaxes/chasm.tmLanguage.json"
    [[ -f "$EXT_SRC/icon.png" ]] && cp "$EXT_SRC/icon.png" "$ext_dir/$EXT_NAME/icon.png"

    # Update registry
    python3 - "$ext_dir/$EXT_NAME" "$reg" <<'PYEOF'
import json, sys, os
ext_path, reg_path = sys.argv[1], sys.argv[2]
if not os.path.exists(reg_path):
    exts = []
else:
    with open(reg_path) as f:
        exts = json.load(f)
exts = [e for e in exts if "chasm" not in str(e.get("identifier",{}).get("id",""))]
exts.append({"identifier":{"id":"chasm.chasm-language"},"version":"0.1.0",
    "location":{"$mid":1,"fsPath":ext_path,"external":f"file://{ext_path}","path":ext_path,"scheme":"file"},
    "relativeLocation":"chasm.chasm-language-0.1.0",
    "metadata":{"isApplicationScoped":False,"isMachineScoped":False,"isBuiltin":False,"installedTimestamp":1773781707291}})
with open(reg_path,"w") as f:
    json.dump(exts,f,indent=2)
PYEOF
    echo "  Extension installed → $ext_dir/$EXT_NAME"
}

install_extension "$HOME/.cursor/extensions"  "$HOME/.cursor/extensions/extensions.json"
install_extension "$HOME/.vscode/extensions"  "$HOME/.vscode/extensions/extensions.json"

echo ""
echo "Done!  Try: chasm compile hello.chasm"
echo "Restart Cursor / VS Code to activate the Chasm extension."
