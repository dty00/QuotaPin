#!/bin/zsh
# 编译并打包成 QuotaPin.app；加 --install 会复制到 ~/Applications
set -e
cd "$(dirname "$0")"
APP=build/QuotaPin.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# 先用默认 SDK；Command Line Tools 里的 SDK 和编译器版本对不上时，依次换其他 SDK 重试
OUT="$APP/Contents/MacOS/QuotaPin"
built=0
setopt nullglob
sdks=(/Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk(On) /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk)
for SDK in "$(xcrun --show-sdk-path 2>/dev/null)" $sdks; do
  [[ -d "$SDK" ]] || continue
  if swiftc -sdk "$SDK" -O -swift-version 5 -o "$OUT" main.swift 2>/tmp/quotapin-build.log; then built=1; break; fi
done
if [[ $built == 0 ]]; then cat /tmp/quotapin-build.log; echo "编译失败：没有找到能用的 macOS SDK"; exit 1; fi
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>QuotaPin</string>
  <key>CFBundleIdentifier</key><string>local.quotapin</string>
  <key>CFBundleExecutable</key><string>QuotaPin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
if [[ "$1" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/QuotaPin.app
  cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/QuotaPin.app"
fi
