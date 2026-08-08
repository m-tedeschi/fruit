#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FRUIT_HOME="${FRUIT_HOME:-$HOME/.fruit}"
INSTALL_DIR="$FRUIT_HOME/bin"
INSTALL_PATH="$INSTALL_DIR/fruit"
ZSHRC="$HOME/.zshrc"
PATH_LINE="export PATH=\"$INSTALL_DIR:\$PATH\""
BLOCK_START="# >>> fruit >>>"
BLOCK_END="# <<< fruit <<<"

cd "$SCRIPT_DIR"

echo "Building Fruit..."
mkdir -p "$SCRIPT_DIR/.build/cache" "$SCRIPT_DIR/.build/clang-module-cache" "$SCRIPT_DIR/.build/swiftpm-module-cache"
export XDG_CACHE_HOME="$SCRIPT_DIR/.build/cache"
export CLANG_MODULE_CACHE_PATH="$SCRIPT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$SCRIPT_DIR/.build/swiftpm-module-cache"
swift build --disable-sandbox -c debug --product fruit

BUILT_BINARY="$SCRIPT_DIR/.build/debug/fruit"

if [ ! -x "$BUILT_BINARY" ]; then
  echo "error: built binary not found at $BUILT_BINARY" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"

if [ -d "$INSTALL_PATH" ]; then
  echo "error: cannot install to $INSTALL_PATH because a directory already exists there" >&2
  exit 1
fi

cp "$BUILT_BINARY" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

touch "$ZSHRC"
if grep -F "$BLOCK_START" "$ZSHRC" >/dev/null 2>&1; then
  echo "Fruit PATH block already exists in $ZSHRC"
elif grep -F "$PATH_LINE" "$ZSHRC" >/dev/null 2>&1; then
  echo "Fruit bin directory is already on PATH in $ZSHRC"
else
  {
    echo
    echo "$BLOCK_START"
    echo "$PATH_LINE"
    echo "$BLOCK_END"
  } >> "$ZSHRC"
  echo "Added Fruit to PATH in $ZSHRC"
fi

echo "Installed Fruit to:"
echo "  $INSTALL_PATH"
echo
echo "Open a new terminal, or update this shell with:"
echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
echo
echo "Then run:"
echo "  fruit doctor"
