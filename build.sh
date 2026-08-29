#!/usr/bin/env bash
#
# Builds NoLid.app and the `nolid` CLI with no Xcode project.
# Requires the Command Line Tools:  xcode-select --install
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="NoLid"
CLI_NAME="nolid"
BUNDLE_ID="dev.nolid.app"
APP="build/${APP_NAME}.app"
CLI="build/${CLI_NAME}"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"

echo "==> Cleaning"
rm -rf "$APP" "$CLI"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Bundle"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/NoLid.icns "$APP/Contents/Resources/NoLid.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Building app (${TARGET})"
# AppKit / CoreGraphics / ServiceManagement / UserNotifications link themselves
# through `import`. Carbon does not: it has to be passed by hand.
swiftc -O -wmo \
    -target "$TARGET" \
    -module-name "$APP_NAME" \
    -framework Carbon \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/${APP_NAME}"

# Shortcuts discovery needs the App Intents metadata bundle that Xcode normally
# produces in a build phase. The processor ships in the Xcode toolchain, not in
# the Command Line Tools, so this step is optional: without it the app still
# works everywhere except the Shortcuts app.
echo "==> App Intents metadata"
TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
PROCESSOR="${TOOLCHAIN}/usr/bin/appintentsmetadataprocessor"

if [ -x "$PROCESSOR" ]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT

    printf '["AppIntent","AppShortcutsProvider","AppEntity","AppEnum","EntityQuery","EntityStringQuery","DynamicOptionsProvider","PersistentlyIdentifiable"]' \
        > "$WORK/protocols.json"

    # Whole-module builds emit one const-values file, keyed by the first source.
    FIRST_SOURCE="$(printf '%s\n' Sources/*.swift | head -1)"
    python3 - "$WORK" "$FIRST_SOURCE" <<'PYMAP'
import glob, json, sys
work, first = sys.argv[1], sys.argv[2]
paths = sorted(glob.glob('Sources/*.swift'))
json.dump({p: {"const-values": f"{work}/module.swiftconstvalues"} if p == first else {}
           for p in paths}, open(f"{work}/outputmap.json", "w"))
PYMAP

    # Each step below is checked by hand instead of leaning on `set -e`. This
    # whole block is optional — the app works without it, only the Shortcuts
    # actions go missing — so a broken or partial Xcode install must not abort
    # the build before the CLI and the code signing that come after it.
    metadata_ok=1

    # -module-name matters: without it swiftc derives the module from the output
    # binary name, and the mangled names baked into the metadata would not match
    # the ones in the shipped app. Shortcuts would list the actions and fail to
    # run them.
    if ! swiftc -O -wmo -target "$TARGET" -module-name "$APP_NAME" -framework Carbon \
        -Xfrontend -const-gather-protocols-file -Xfrontend "$WORK/protocols.json" \
        -Xfrontend -supplementary-output-file-map -Xfrontend "$WORK/outputmap.json" \
        Sources/*.swift -o "$WORK/scan" >/dev/null 2>&1
    then
        metadata_ok=0
    fi

    if [ "$metadata_ok" -eq 1 ]; then
        printf '%s\n' "$PWD"/Sources/*.swift > "$WORK/sources.txt"
        echo "$WORK/module.swiftconstvalues" > "$WORK/constvals.txt"

        if ! "$PROCESSOR" \
            --output "$APP/Contents/Resources" \
            --toolchain-dir "$TOOLCHAIN" \
            --module-name "$APP_NAME" \
            --sdk-root "$(xcrun --show-sdk-path)" \
            --xcode-version "$(xcodebuild -version | sed -n 's/^Build version //p')" \
            --platform-family macOS \
            --deployment-target 13.0 \
            --target-triple "$TARGET" \
            --source-file-list "$WORK/sources.txt" \
            --swift-const-vals-list "$WORK/constvals.txt" \
            --force --quiet-warnings >/dev/null 2>&1
        then
            metadata_ok=0
        fi
    fi

    if [ "$metadata_ok" -eq 1 ]; then
        echo "    Metadata.appintents written"
    else
        echo "    skipped: the metadata step failed, Shortcuts actions will be missing"
    fi
else
    echo "    skipped: needs the full Xcode toolchain, Shortcuts actions will be missing"
fi

echo "==> Building CLI (${TARGET})"
# The CLI shares DisplayAPI with the app: `panic`, `on` and `doctor` have to
# work without the app running.
swiftc -O -wmo \
    -target "$TARGET" \
    Sources/DisplayAPI.swift Sources/DisplayBackend.swift Sources/CapabilityProbe.swift \
    Sources/CommandLineOptions.swift Sources/RemoteControl.swift \
    CLI/*.swift \
    -o "$CLI"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --force --sign - --identifier "${BUNDLE_ID}.cli" "$CLI"
touch "$APP"   # invalidates the LaunchServices cache

echo
echo "Done: $APP"
echo "       $CLI"
echo
echo "Try:      open $APP"
echo "Install:  cp -R $APP /Applications/ && open /Applications/${APP_NAME}.app"
echo "CLI:      sudo cp $CLI /usr/local/bin/ && ${CLI_NAME} doctor"
