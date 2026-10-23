#!/usr/bin/env bash
# packs build/Peek.app into build/Peek.dmg, then notarizes and staples it when a notary profile
# exists (xcrun notarytool store-credentials <profile>). it only prints ✓ notarized when apple says
# Accepted and the staple validates, so a half-done dmg never looks shippable.
set -euo pipefail
cd "$(dirname "$0")/.."

app=build/Peek.app
dmg=build/Peek.dmg
[ -d "$app" ] || { echo "build the app first: scripts/build.sh"; exit 1; }

# dmgbuild writes the finder layout without finder. kept in ~/Library/Caches, not /tmp, which macos prunes
venv="$HOME/Library/Caches/peek-dmgbuild"
"$venv/bin/python3" -c "import dmgbuild, ds_store" 2>/dev/null || { rm -rf "$venv" && python3 -m venv "$venv" && "$venv/bin/pip" install --quiet dmgbuild; }

rm -f "$dmg"
"$venv/bin/dmgbuild" -s App/dmg/settings.py -D app="$app" "Peek" "$dmg"

identity=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
[ -n "$identity" ] && codesign --force --timestamp --sign "$identity" "$dmg"

profile="${NOTARY_PROFILE:-pavo}"
if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
  echo "  not notarized: no '$profile' notary profile in the keychain"
  exit 0
fi

echo "→ notarizing (a few minutes)"
# uploads drop on flaky connections; retry the upload, then wait on the submission id
id=""
for attempt in 1 2 3 4; do
  id=$(xcrun notarytool submit "$dmg" --keychain-profile "$profile" --output-format json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" || true)
  [ -n "$id" ] && break
  echo "  upload failed, retrying ($attempt)"
  sleep 5
done
[ -n "$id" ] || { echo "✗ could not upload to the notary service"; exit 1; }
echo "  submission $id"
until xcrun notarytool wait "$id" --keychain-profile "$profile" >/dev/null 2>&1; do sleep 10; done

status=$(xcrun notarytool info "$id" --keychain-profile "$profile" --output-format json \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))")
if [ "$status" != "Accepted" ]; then
  echo "✗ notarization: $status"
  xcrun notarytool log "$id" --keychain-profile "$profile" || true
  exit 1
fi
xcrun stapler staple "$dmg" >/dev/null
xcrun stapler validate "$dmg" >/dev/null || { echo "✗ staple didn't validate"; exit 1; }
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "✓ notarized $dmg ($(du -h "$dmg" | cut -f1))"
