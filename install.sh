#!/usr/bin/env sh
# install.sh — Chasm installer for macOS and Linux
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Chasm-lang/Chasm/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/Chasm-lang/Chasm/main/install.sh | sh -s -- --prefix /usr/local

set -e

REPO="Chasm-lang/Chasm"
INSTALL_DIR="${CHASM_HOME:-$HOME/.chasm}"
BIN_DIR="$HOME/.local/bin"

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) BIN_DIR="$2/bin"; shift 2 ;;
    --dir)    INSTALL_DIR="$2"; shift 2 ;;
    *)        shift ;;
  esac
done

# Detect platform
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin) OS_NAME="macos" ;;
  Linux)  OS_NAME="linux" ;;
  *)
    echo "Unsupported OS: $OS"
    echo "Install manually: https://github.com/$REPO/releases"
    exit 1
    ;;
esac

case "$ARCH" in
  arm64|aarch64) ARCH_NAME="arm64" ;;
  x86_64|amd64)  ARCH_NAME="x86_64" ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# Fetch latest release tag
echo "Fetching latest Chasm release..."
TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | sed 's/.*"tag_name": "\(.*\)".*/\1/')"

if [ -z "$TAG" ]; then
  echo "Could not determine latest release. Check https://github.com/$REPO/releases"
  exit 1
fi

ARCHIVE="chasm-${TAG}-${OS_NAME}-${ARCH_NAME}.tar.gz"
URL="https://github.com/$REPO/releases/download/${TAG}/${ARCHIVE}"

echo "Installing Chasm $TAG for ${OS_NAME}-${ARCH_NAME}..."
echo "  from: $URL"
echo "  to:   $INSTALL_DIR"

# Download and extract
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$URL" -o "$TMP/$ARCHIVE"
tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
EXTRACTED="$TMP/chasm-${TAG}-${OS_NAME}-${ARCH_NAME}"

# Install
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -r "$EXTRACTED/." "$INSTALL_DIR/"

# Make binaries executable
chmod +x "$INSTALL_DIR/bootstrap/bin/"*
chmod +x "$INSTALL_DIR/bin/chasm"
[ -f "$INSTALL_DIR/bin/chasm-lsp" ] && chmod +x "$INSTALL_DIR/bin/chasm-lsp"

# Symlink CLI and LSP into BIN_DIR
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/bin/chasm" "$BIN_DIR/chasm"
[ -f "$INSTALL_DIR/bin/chasm-lsp" ] && ln -sf "$INSTALL_DIR/bin/chasm-lsp" "$BIN_DIR/chasm-lsp"

echo ""
echo "Chasm $TAG installed to $INSTALL_DIR"
echo "CLI symlinked to $BIN_DIR/chasm"

# PATH hint
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo ""
    echo "NOTE: $BIN_DIR is not in your PATH."
    SHELL_NAME="$(basename "${SHELL:-sh}")"
    case "$SHELL_NAME" in
      zsh)  echo "  echo 'export PATH=\"\$PATH:$BIN_DIR\"' >> ~/.zshrc && source ~/.zshrc" ;;
      fish) echo "  echo 'fish_add_path $BIN_DIR' >> ~/.config/fish/config.fish" ;;
      *)    echo "  echo 'export PATH=\"\$PATH:$BIN_DIR\"' >> ~/.bashrc && source ~/.bashrc" ;;
    esac
    ;;
esac

echo ""
echo "Try: chasm run examples/hello/hello.chasm"
