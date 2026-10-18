#!/bin/sh
# Installs rr2fix into Real Racing 2 for Mac, or removes it.
#
#   ./install.sh               build and install
#   ./install.sh --uninstall   restore the app to how it was
#
# Uses /Applications/Real Racing 2.app unless APP is set:
#   APP="$HOME/Games/Real Racing 2.app" ./install.sh
set -eu

APP="${APP:-/Applications/Real Racing 2.app}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
MACOS="$APP/Contents/MacOS"
FRAMEWORKS="$APP/Contents/Frameworks"
EXE="$MACOS/Real Racing 2"
ORIG="$MACOS/Real Racing 2.bin"

[ -d "$APP" ] || { echo "Can't find $APP. Set APP=/path/to/Real Racing 2.app"; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
    [ -f "$ORIG" ] || { echo "Not installed, nothing to do."; exit 0; }
    rm -f "$EXE" "$FRAMEWORKS/rr2fix.dylib"
    mv "$ORIG" "$EXE"
    echo "Removed rr2fix. The app is back to its original state."
    exit 0
fi

command -v clang >/dev/null || { echo "clang not found. Run: xcode-select --install"; exit 1; }

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
[ "$VERSION" = "1.1.2" ] || echo "Warning: tested with version 1.1.2, this app is $VERSION. Trying anyway."

mkdir -p "$BUILD"
CFLAGS="-arch x86_64 -mmacosx-version-min=10.13 -dynamiclib -fobjc-arc -O2 -Wno-deprecated-declarations"
echo "Building rr2fix.dylib..."
clang $CFLAGS -framework Cocoa -framework OpenGL -framework AudioToolbox -framework CoreAudio \
    -o "$BUILD/rr2fix.dylib" "$HERE/src/rr2fix.m"

# Move the real executable aside once. Re-running only refreshes the dylib.
if [ ! -f "$ORIG" ]; then
    file "$EXE" | grep -q "Mach-O" || { echo "Unexpected executable: $EXE"; exit 1; }
    mv "$EXE" "$ORIG"
fi

cp "$BUILD/rr2fix.dylib" "$FRAMEWORKS/"

cat > "$EXE" <<'EOF'
#!/bin/sh
# Added by rr2fix: loads the fix library, then starts the real game.
# To undo by hand, delete this file and rename "Real Racing 2.bin" back to "Real Racing 2".
DIR="$(cd "$(dirname "$0")" && pwd)"
export DYLD_INSERT_LIBRARIES="$DIR/../Frameworks/rr2fix.dylib"
exec "$DIR/Real Racing 2.bin" "$@"
EOF
chmod +x "$EXE"

echo "Installed into $APP"
echo "Start the game and press Space to get past the intro screen."
