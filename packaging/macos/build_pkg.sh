#!/bin/bash
# Build Hibiki-<version>.pkg on macOS: the suite + a bundled Python (both arches; postinstall keeps the
# host's) under /Library/Application Support/Hibiki, and a postinstall that runs `setup` for the logged-in user.
#   packaging/macos/build_pkg.sh [out_dir]          (default dist/)
# Signing is optional: DEV_ID_APP="Developer ID Application: …" signs the Mach-O files with the hardened runtime,
# DEV_ID_INSTALLER="Developer ID Installer: …" signs the pkg, NOTARY_PROFILE=<notarytool keychain profile> notarizes
# and staples it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$(mkdir -p "${1:-$REPO/dist}" && cd "${1:-$REPO/dist}" && pwd)"
ID=io.github.yiw190.hibiki
VERSION=$(sed -n 's/^__version__ = "\([^"]*\)".*/\1/p' "$REPO/reaper_mcp/__init__.py")
PKGVER=${VERSION%%-*}  # Installer compares package versions numerically: 0.5.0-rc.1 -> 0.5.0
# shellcheck disable=SC1091
. "$HERE/../python.lock"
[ "$(uname)" = Darwin ] || { echo "build_pkg.sh needs macOS (pkgbuild, productbuild)" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/root/Library/Application Support/Hibiki"
mkdir -p "$APP/app" "$APP/bin" "$WORK/cache"
echo "hibiki $VERSION, python $PY ($TAG)"

# --- bundled Python, one per arch ---
CACHE="${PY_CACHE:-$HOME/.cache/hibiki}"
mkdir -p "$CACHE"
for arch in arm64 x86_64; do
  triple=$([ $arch = arm64 ] && echo aarch64 || echo x86_64)-apple-darwin
  name="cpython-$PY+$TAG-$triple-install_only_stripped.tar.gz"
  tgz="$CACHE/$name"
  if [ ! -f "$tgz" ]; then
    curl -fsSL -o "$tgz.part" "https://github.com/astral-sh/python-build-standalone/releases/download/$TAG/$name"
    mv "$tgz.part" "$tgz"
  fi
  want=$(eval echo "\$SHA_$arch")
  got=$(shasum -a 256 "$tgz" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { echo "sha256 mismatch for $name: $got" >&2; rm -f "$tgz"; exit 1; }
  mkdir -p "$WORK/py-$arch"
  tar -xzf "$tgz" -C "$WORK/py-$arch"
  mv "$WORK/py-$arch/python" "$APP/python-$arch"
  lib="$APP/python-$arch/lib/python${PY%.*}"
  # nothing in the suite uses these; ~20 MB less per arch
  rm -rf "$lib/test" "$lib/idlelib" "$lib/turtledemo" "$lib/tkinter" "$lib/ensurepip" "$lib/lib2to3" \
    "$lib"/lib-dynload/_tkinter* "$APP/python-$arch"/lib/libtcl* "$APP/python-$arch"/lib/libtk* \
    "$APP/python-$arch"/lib/tcl* "$APP/python-$arch"/lib/tk* "$APP/python-$arch/share"
done

# --- Hibiki.app: the Python binary inside an app bundle, so Login Items and privacy prompts name Hibiki, not python3.
# Python finds its stdlib by walking up from Contents/MacOS to python-<arch>/lib; bin/python3.12 links to it.
ICONSET="$WORK/Hibiki.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  cp "$REPO/icons/hibiki-$s.png" "$ICONSET/icon_${s}x${s}.png"
  cp "$REPO/icons/hibiki-$((s * 2)).png" "$ICONSET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$WORK/Hibiki.icns"
for arch in arm64 x86_64; do
  B="$APP/python-$arch/Hibiki.app/Contents"
  mkdir -p "$B/MacOS" "$B/Resources"
  mv "$APP/python-$arch/bin/python${PY%.*}" "$B/MacOS/Hibiki"
  ln -s "../Hibiki.app/Contents/MacOS/Hibiki" "$APP/python-$arch/bin/python${PY%.*}"
  sed "s/@ID@/$ID/g; s/@PKGVER@/$PKGVER/g; s/@VERSION@/$VERSION/g" "$HERE/Info.plist" > "$B/Info.plist"
  cp "$WORK/Hibiki.icns" "$B/Resources/"
done

# --- the suite ---
( cd "$REPO" && tar -cf - --exclude '__pycache__' --exclude '*.pyc' --exclude 'test_*.py' --exclude 'fake_*' \
    reaper_mcp brain gateway panel reaper scripts/reaper-watchdog.sh LICENSE README.md ) | tar -xf - -C "$APP/app"
host_py="$APP/python-$( [ "$(uname -m)" = arm64 ] && echo arm64 || echo x86_64 )/bin/python3"
"$host_py" -m compileall -q "$APP/app"  # the payload is read-only for users: ship the bytecode
echo "$VERSION" > "$APP/VERSION"
cat > "$APP/bin/hibiki" << 'EOF'
#!/bin/sh
APP="/Library/Application Support/Hibiki"
exec "$APP/python/Hibiki.app/Contents/MacOS/Hibiki" -s -E "$APP/app/reaper_mcp/cli.py" "$@"
EOF
chmod 755 "$APP/bin/hibiki"

# --- code signing: Developer ID when given, else ad-hoc (seals Info.plist, so the app's identity is its bundle id) ---
if [ -n "${DEV_ID_APP:-}" ]; then
  find "$APP" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -not -path '*/Hibiki.app/*' -print0 |
    while IFS= read -r -d '' f; do
      file -b "$f" | grep -q Mach-O || continue
      codesign --force --timestamp --options runtime --entitlements "$HERE/entitlements.plist" -s "$DEV_ID_APP" "$f"
    done
fi
sign=(-s -)
[ -z "${DEV_ID_APP:-}" ] || sign=(-s "$DEV_ID_APP" --timestamp --options runtime --entitlements "$HERE/entitlements.plist")
for arch in arm64 x86_64; do
  codesign --force -i "$ID" "${sign[@]}" "$APP/python-$arch/Hibiki.app"
  codesign --verify --strict "$APP/python-$arch/Hibiki.app"
done

# --- pkg ---
sed "s/@VERSION@/$VERSION/g" "$HERE/resources/conclusion.html" > "$WORK/conclusion.html"
mkdir -p "$WORK/resources"
cp "$HERE/resources/welcome.html" "$WORK/resources/"
mv "$WORK/conclusion.html" "$WORK/resources/"
cp "$REPO/LICENSE" "$WORK/resources/LICENSE.txt"
chmod -R go-w "$WORK/root"
# Installer would otherwise move a bundle to wherever another app with the same id lives, or skip it as "older"
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist"
"$host_py" -c 'import plistlib, sys
p = sys.argv[1]
c = plistlib.load(open(p, "rb"))
for b in c:
    b["BundleIsRelocatable"] = False
    b["BundleIsVersionChecked"] = False
plistlib.dump(c, open(p, "wb"))' "$WORK/components.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" --scripts "$HERE/scripts" --identifier "$ID" \
  --version "$PKGVER" --install-location / --ownership recommended "$WORK/core.pkg"
sed "s/@PKGVER@/$PKGVER/g; s/@VERSION@/$VERSION/g; s/@ID@/$ID/g" "$HERE/Distribution.xml" > "$WORK/Distribution.xml"
PKG="$OUT/Hibiki-$VERSION.pkg"
productbuild --distribution "$WORK/Distribution.xml" --resources "$WORK/resources" --package-path "$WORK" \
  ${DEV_ID_INSTALLER:+--sign "$DEV_ID_INSTALLER"} "$PKG"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi
( cd "$OUT" && shasum -a 256 "$(basename "$PKG")" > "$(basename "$PKG").sha256" )
ls -l "$PKG"
