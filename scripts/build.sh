#!/usr/bin/env bash
# builds build/Peek.app: the menu bar app with the siglip models compiled inside it.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(cat VERSION)
app=build/Peek.app

if [ ! -d models/ImageEncoder.mlpackage ]; then
  echo "no models/ yet: run scripts/convert-model.py first (see its header)" >&2
  exit 1
fi

echo "→ app"
swift build -c release
bin=$(swift build -c release --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Models/tokenizer"
cp "$bin/Peek" "$app/Contents/MacOS/Peek"
sed "s/__VERSION__/$version/g" App/Info.plist > "$app/Contents/Info.plist"
# swiftpm resource bundles from dependencies (swift-transformers ships some) sit next to the binary
for bundle in "$bin"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done

echo "→ icon"
work=$(mktemp -d)
mkdir "$work/Peek.iconset"
swift scripts/render-svg.swift App/AppIcon.svg "$work/icon" 16 32 64 128 256 512 1024
for size in 16 32 128 256 512; do
  cp "$work/icon-$size.png" "$work/Peek.iconset/icon_${size}x${size}.png"
  cp "$work/icon-$((size * 2)).png" "$work/Peek.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$work/Peek.iconset" -o "$app/Contents/Resources/Peek.icns"
rm -rf "$work"

echo "→ models"
for model in ImageEncoder TextEncoder; do
  xcrun coremlcompiler compile "models/$model.mlpackage" "$app/Contents/Resources/Models" >/dev/null
done
cp models/siglip.json "$app/Contents/Resources/Models/"
cp App/places.json "$app/Contents/Resources/"
cp models/tokenizer/{tokenizer.json,tokenizer_config.json,special_tokens_map.json} "$app/Contents/Resources/Models/tokenizer/"

# sign with your Developer ID if it's in the keychain, otherwise ad-hoc for local runs
identity=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$identity" ]; then
  sign=(codesign --force --options runtime --timestamp --sign "$identity")
else
  sign=(codesign --force --options runtime --sign -)
fi
"${sign[@]}" --entitlements App/Peek.entitlements "$app"
echo "  signed: ${identity:-ad-hoc (local only)}"

echo "✓ $app ($(du -sh "$app" | cut -f1))"
