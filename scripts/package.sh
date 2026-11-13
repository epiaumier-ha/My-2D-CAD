#!/bin/zsh
# Construit My2DCAD.app (Release) et ses packages d'installation dans dist/ :
#   dist/My2DCAD-<version>.dmg  image disque : glisser l'app dans Applications
#   dist/My2DCAD-<version>.pkg  installeur macOS (installe dans /Applications)
#
# Usage : scripts/package.sh [--install]
#   --install : installe ensuite l'app depuis le .dmg dans /Applications (sans mot de passe
#               pour un compte administrateur), en remplaçant la version précédente.
#
# Signature : identité « Apple Development » du trousseau si elle existe (signature stable
# d'une version à l'autre : le Trousseau ne redemande pas l'accès à la clé API), sinon ad hoc.
# Ces packages conviennent à ce Mac ; une diffusion à d'autres Mac demande une identité
# « Developer ID » et la notarisation d'Apple.

set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

APP_NAME="My2DCAD"
BUNDLE_ID="fr.my2dcad.app"
SHORT_VERSION="1.0"
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
VERSION="$SHORT_VERSION.$BUILD_NUMBER"
DIST="$ROOT/dist"
# Assemblage hors du dossier du projet : Documents synchronisé par iCloud ajoute des attributs
# étendus (FinderInfo) que codesign refuse.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/My2DCAD-package.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/$APP_NAME.app"

INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    *) print -u2 "Option inconnue : $arg"; exit 2 ;;
  esac
done

step() { print "\n▸ $1" }

step "Compilation Release"
swift build -c release --product "$APP_NAME"
BIN_DIR=$(swift build -c release --show-bin-path)

step "Assemblage de $APP_NAME.app ($VERSION)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Icône : PNG 1024 px généré, puis toutes les tailles du format .icns.
swift scripts/make-icon.swift "$WORK/icon-1024.png" >/dev/null
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleDisplayName</key><string>My 2D CAD</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Emmanuel Piaumier</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

step "Signature"
# Attributs étendus (provenance, Finder) déposés par les outils : refusés par codesign.
xattr -cr "$APP"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
if [[ -n "$IDENTITY" ]] && codesign --force --timestamp=none --sign "$IDENTITY" "$APP" 2>/dev/null; then
  print "Signée avec : $IDENTITY"
else
  codesign --force --sign - "$APP"
  print "Signature ad hoc (aucune identité de signature utilisable)"
fi
codesign --verify --strict "$APP"

# Seule la dernière version est gardée dans dist/.
rm -f "$DIST/$APP_NAME"-*.dmg "$DIST/$APP_NAME"-*.pkg

step "Image disque (.dmg)"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto --norsrc --noextattr "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"

step "Installeur (.pkg)"
PKG="$DIST/$APP_NAME-$VERSION.pkg"
PKGROOT="$WORK/pkgroot"
mkdir -p "$PKGROOT"
ditto --norsrc --noextattr "$APP" "$PKGROOT/$APP_NAME.app"
# Toujours dans /Applications : sans cela, l'installeur mettrait à jour une copie trouvée ailleurs.
pkgbuild --analyze --root "$PKGROOT" "$WORK/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"
rm -f "$PKG"
COPYFILE_DISABLE=1 pkgbuild --quiet --root "$PKGROOT" --component-plist "$WORK/component.plist" \
  --identifier "$BUNDLE_ID.pkg" --version "$VERSION" --install-location /Applications "$PKG"

step "Packages prêts"
ls -lh "$DMG" "$PKG"

if $INSTALL; then
  step "Installation dans /Applications (depuis le .dmg)"
  # App installée ouverte : fermeture normale (comme ⌘Q), qui propose d'enregistrer le dessin.
  # Si l'utilisateur annule, rien n'est remplacé. La version lancée par « swift run » n'est pas concernée.
  WAS_RUNNING=false
  if pgrep -f "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null; then
    WAS_RUNNING=true
    print "My2DCAD est ouverte : demande de fermeture (enregistrez votre dessin si on vous le propose)…"
    cat > "$WORK/quit.swift" <<'SWIFT'
import AppKit
for app in NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1]) { app.terminate() }
SWIFT
    swift "$WORK/quit.swift" "$BUNDLE_ID"
    for _ in {1..120}; do
      pgrep -f "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null || break
      sleep 1
    done
    if pgrep -f "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null; then
      print -u2 "My2DCAD est toujours ouverte (fermeture annulée) : installation abandonnée. Les packages sont dans dist/."
      exit 1
    fi
  fi
  MOUNT=$(mktemp -d)
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
  trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; rm -rf "$WORK"' EXIT
  rm -rf "/Applications/$APP_NAME.app"
  ditto --norsrc --noextattr "$MOUNT/$APP_NAME.app" "/Applications/$APP_NAME.app"
  codesign --verify --strict "/Applications/$APP_NAME.app"
  print "Installée : /Applications/$APP_NAME.app ($VERSION)"
  # L'app était ouverte : elle est rouverte dans sa nouvelle version.
  if $WAS_RUNNING; then open "/Applications/$APP_NAME.app"; print "Rouverte."; fi
fi
