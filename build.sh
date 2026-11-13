#!/bin/zsh
# Собирает Бодрячок.app (универсальный: Apple Silicon + Intel, macOS 13+).
#   ./build.sh            только сборка
#   ./build.sh --install  сборка, установка в /Applications и перезапуск
#   ./build.sh --dist     сборка и Бодрячок.dmg для передачи на другие Mac
set -e
cd "$(dirname "$0")"
APP="Бодрячок.app"
MIN=13.0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O main.swift -target "$arch-apple-macos$MIN" -o "$TMP/bin-$arch" \
    -framework Cocoa -framework IOKit -framework ServiceManagement -framework UserNotifications
done
lipo -create "$TMP/bin-arm64" "$TMP/bin-x86_64" -output "$APP/Contents/MacOS/Bodryachok"

# Иконка: рисуем 1024px PNG и собираем AppIcon.icns
swiftc make_icon.swift -o "$TMP/mkicon"
"$TMP/mkicon" "$TMP/icon.png" >/dev/null
sips -z 1024 1024 "$TMP/icon.png" >/dev/null
# Стандартный профиль sRGB вместо профиля дисплея, на котором шла сборка
sips -m "/System/Library/ColorSync/Profiles/sRGB Profile.icc" "$TMP/icon.png" >/dev/null
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$TMP/icon.png" icon_1024.png

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Бодрячок</string>
  <key>CFBundleDisplayName</key><string>Бодрячок</string>
  <key>CFBundleExecutable</key><string>Bodryachok</string>
  <key>CFBundleIdentifier</key><string>local.bodryachok</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>$MIN</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" 2>/dev/null
echo "Готово: $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/Bodryachok"))"

if [[ "$1" == "--install" ]]; then
  pkill -x Bodryachok || true
  sleep 1
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
  echo "Установлено и запущено: /Applications/$APP"
fi

if [[ "$1" == "--dist" ]]; then
  STAGE="$TMP/dmg"
  mkdir "$STAGE"
  cp -R "$APP" "$STAGE/"
  cp "Как установить.txt" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "Бодрячок.dmg"
  # Без расширенных атрибутов и в UTC: в образ не попадают метки и часовой пояс этого Mac
  xattr -cr "$STAGE"
  TZ=UTC hdiutil create -volname "Бодрячок" -srcfolder "$STAGE" -fs APFS -ov -format UDZO "Бодрячок.dmg" >/dev/null
  echo "Образ для передачи: $(pwd)/Бодрячок.dmg"
fi
