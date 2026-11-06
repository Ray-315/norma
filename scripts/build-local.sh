#!/bin/zsh
# Uses explicit toolchain paths without modifying xcode-select.
set -eu
cd "$(dirname "$0")/.."
toolchain=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
sdk=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk
SDKROOT="$sdk" "$toolchain/swift" build --sdk "$sdk" --build-system native -j 4
products=.build/arm64-apple-macosx/debug
destination=artifacts/local/NORMA.app
if [[ -x "$destination/Contents/MacOS/NORMA" ]]; then
  database="$HOME/Library/Application Support/NORMA/research.sqlite"
  if [[ -f "$database" ]]; then
    active=$(/usr/bin/sqlite3 "$database" "SELECT count(*) FROM research WHERE json_extract(CAST(payload AS TEXT),'$.operation') IN ('running','cancelPending','unknown');")
    if [[ "$active" != 0 ]]; then
      print -u2 "Research execution requires reconciliation before replacing the helper."
      exit 1
    fi
  fi
  "$destination/Contents/MacOS/NORMA" --unregister-service
fi
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources" "$destination/Contents/Library/LaunchAgents"
cp "$products/NORMA" "$destination/Contents/MacOS/NORMA"
cp "$products/NORMAResearchService" "$destination/Contents/MacOS/NORMAResearchService"
cp workers/experiment-runner/worker.py "$destination/Contents/Resources/"
cp apps/NORMAApp/app.norma.research.plist "$destination/Contents/Library/LaunchAgents/"
ditto "$products/GRDB_GRDB.bundle" "$destination/Contents/Resources/GRDB_GRDB.bundle"
cat > "$destination/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.norma.desktop</string>
<key>CFBundleName</key><string>NORMA</string>
<key>CFBundleDisplayName</key><string>NORMA</string>
<key>CFBundleExecutable</key><string>NORMA</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$destination/Contents/MacOS/NORMAResearchService"
/usr/bin/codesign --force --sign - "$destination"
/usr/bin/codesign --verify --strict "$destination"
printf '%s\n' "$PWD/$destination"
