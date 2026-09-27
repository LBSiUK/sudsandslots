#!/bin/bash
# Build Suds & Slots as a fake-signed iOS 15 app and package it as Sileo .debs
# (both rootless and rootful) for a jailbroken iPad Mini 4 on iOS 15.8.4.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
SRC="$ROOT/Sources/SudsAndSlots"
PKG="$ROOT/packaging"
BUILD="$ROOT/build"
APP="$BUILD/SudsAndSlots.app"

VERSION="0.1"
BUNDLE_ID="com.leonb.sudsandslots"
DEPLOY_TARGET="15.0"

rm -rf "$BUILD"
mkdir -p "$APP"

SDKPATH="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "==> Compiling (arm64, iOS $DEPLOY_TARGET) against $(basename "$SDKPATH")"

xcrun --sdk iphoneos swiftc \
    -sdk "$SDKPATH" \
    -target "arm64-apple-ios${DEPLOY_TARGET}" \
    -swift-version 5 \
    -O \
    -parse-as-library \
    "$SRC"/*.swift \
    -o "$APP/SudsAndSlots"

echo "==> Assembling app bundle"
cp "$PKG/Info.plist" "$APP/Info.plist"
# App icon (flask on purple) — named for SpringBoard's CFBundleIconFiles lookup.
if [ -d "$PKG/appicon" ]; then
    cp "$PKG/appicon/icon_120.png" "$APP/AppIcon60x60@2x.png"
    cp "$PKG/appicon/icon_180.png" "$APP/AppIcon60x60@3x.png"
    cp "$PKG/appicon/icon_152.png" "$APP/AppIcon76x76@2x.png"
    cp "$PKG/appicon/icon_167.png" "$APP/AppIcon83.5x83.5@2x.png"
    echo "    bundled app icon"
fi

echo "==> Fake-signing with entitlements"
# -I keeps the code-signing identifier equal to the bundle id.
ldid -S"$PKG/entitlements.plist" -I"$BUNDLE_ID" "$APP/SudsAndSlots"

# --- Package helper -------------------------------------------------------
# $1 = variant name  $2 = architecture  $3 = install prefix (relative)
make_deb() {
    local variant="$1" arch="$2" prefix="$3"
    local stage="$BUILD/deb-$variant"
    local appdir="$stage/$prefix/Applications"
    rm -rf "$stage"
    mkdir -p "$appdir" "$stage/DEBIAN"
    cp -R "$APP" "$appdir/"

    cat > "$stage/DEBIAN/control" <<EOF
Package: $BUNDLE_ID
Name: Suds & Slots
Version: $VERSION
Architecture: $arch
Description: Book laundry slots for the household.
Maintainer: leonb
Author: leonb
Section: Utilities
Depends: firmware (>= 15.0)
EOF

    # Quoted heredoc: keep runtime shell vars literal; paths/id filled by sed below.
    cat > "$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
uicache -p "__APPPATH__" 2>/dev/null || uicache -a
exit 0
EOF
    # Fill in the app path (quoted heredoc left it literal),
    # then collapse // and /./ so the path is clean for rootful (prefix=".").
    sed -i '' "s#__APPPATH__#/$prefix/Applications/SudsAndSlots.app#g; s#/\./#/#g; s#//#/#g" "$stage/DEBIAN/postinst"
    chmod 0755 "$stage/DEBIAN/postinst"

    local out="$BUILD/SudsAndSlots_${VERSION}_${variant}.deb"
    if dpkg-deb --root-owner-group -Zgzip --build "$stage" "$out" >/dev/null 2>&1; then :; else
        dpkg-deb -Zgzip --build "$stage" "$out" >/dev/null
    fi
    echo "    $out"
}

echo "==> Building .debs"
make_deb "rootless" "iphoneos-arm64" "var/jb"
make_deb "rootful"  "iphoneos-arm"   "."

echo "==> Done."
ls -lh "$BUILD"/*.deb
