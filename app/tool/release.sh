#!/usr/bin/env bash
# Builds the release APK, checks it, and makes it ready for the app's own updates (Settings > Updates).
#
# usage: app/tool/release.sh [--publish] [--size-ok] ["a line of what changed" ...]
#   --size-ok: the APK may be more than 200 KB bigger than the last one built here (without it the script stops)
#   The notes people read under Settings > Updates come from app/release-notes/<version>.txt (English) and
#   <version>.vi.txt (Vietnamese; shown when the app speaks Vietnamese). A line starting with "- " is a bullet, any
#   other line is a heading. Lines given on the command line replace the English file.
#   Two APKs are built every time, one per kind of phone: arm64 (most phones) and arm32 (phones with a 32-bit Android, such
#   as the Galaxy J7 Prime). A 32-bit phone cannot run the first, and the file for it is listed under "arm32" in latest.json.
#   without --publish: builds into ~/sapoche-release-arm64-<version>.apk and ~/sapoche-release-arm32-<version>.apk and writes the update files next to them
#   with --publish:    first opens the APK on the emulator (app/tool/smoke.sh) and stops if it crashes; then
#                      puts the files in the private R2 bucket (needs `wrangler login`; the APK first, then
#                      latest.json, so a phone never reads news of a file that is not there yet; the file is
#                      named sapoche-<version>.apk, and latest.json says so); then a copy WITHOUT the room key
#                      (sapoche-<version>-android.apk in $HOME) goes on the GitHub release v<version> (app/tool/github_release.py)
#
# Bump `version:` in pubspec.yaml first: a phone only offers an update whose build number is higher.
set -euo pipefail

PUBLISH=0
SIZE_OK=0
while [ "${1:-}" = "--publish" ] || [ "${1:-}" = "--size-ok" ]; do
  [ "$1" = "--publish" ] && PUBLISH=1 || SIZE_OK=1
  shift
done

APP=$(cd "$(dirname "$0")/.." && pwd)
SERVER=$(cd "$APP/../server" && pwd)
FLUTTER=${FLUTTER:-$HOME/.local/share/flutter/bin/flutter}
BUILD_TOOLS=$(ls -d "${ANDROID_HOME:-$HOME/Android/Sdk}"/build-tools/* | sort -V | tail -1)
# wrangler needs Node 22 or newer; NODE_BIN is the folder of a Node that is not the one on the PATH, if there is one
export PATH=${NODE_BIN:+$NODE_BIN:}$PATH

VERSION=$(sed -n 's/^version: *//p' "$APP/pubspec.yaml")
NOTES_ARGS=("$@")
NAME=${VERSION%+*}
CODE=${VERSION#*+}
[ "$NAME" != "$VERSION" ] || { echo "pubspec.yaml version needs a build number (1.2.3+4)"; exit 1; }

cd "$APP"
# Debug symbols are kept out of the app and names are obfuscated (about 1.5 MB less); a Dart stack trace copied from a log
# is read again with `flutter symbolize -i trace.txt -d $SYMBOLS` (the folder is per version, keep it), and R8's
# mapping.txt, saved next to the symbols, reads one of the Kotlin libraries (the app's own code keeps its names)
SYMBOLS=$HOME/sapoche-symbols/$NAME
mkdir -p "$SYMBOLS"
SHRINK=(--split-debug-info="$SYMBOLS" --obfuscate)
# Builds the APK of one kind of phone into $HOME/sapoche-release-<abi>-<version>.apk and checks it. It sets OUT (the file),
# SHA, SIZE and GZSIZE (the gzipped copy next to it, for the phones that know how to unpack it: about a third less to
# fetch; the plain apk stays for older ones).
build_apk() {
  local abi=$1 platform=$2 lib=$3
  "$FLUTTER" build apk --release --target-platform "$platform" "${SHRINK[@]}"
  OUT=$HOME/sapoche-release-$abi-$NAME.apk
  cp build/app/outputs/flutter-apk/app-release.apk "$OUT"
  [ "$abi" = arm64 ] && cp build/app/outputs/mapping/release/mapping.txt "$SYMBOLS/mapping.txt"

  # Signed with the release key, not the debug one: the debug key would install but could never update the real app
  "$BUILD_TOOLS/apksigner" verify --print-certs "$OUT" | grep "SHA-256" | head -1
  if "$BUILD_TOOLS/apksigner" verify --print-certs "$OUT" | grep -q "Android Debug"; then
    echo "signed with the debug key; sapoche.properties has no release keystore"; exit 1
  fi
  local badging
  badging=$("$BUILD_TOOLS/aapt2" dump badging "$OUT")
  echo "$badging" | grep -q "versionCode='$CODE'" || { echo "the APK does not carry build number $CODE"; exit 1; }
  echo "$badging" | grep -q "application-debuggable" && { echo "the APK is debuggable"; exit 1; }
  check_abi "$OUT" "$lib"

  SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
  SIZE=$(stat -c %s "$OUT")
  # The size is watched: a library or a font that came in with a change should be a choice, not a surprise. It is compared
  # with the newest APK of this kind this script built before this one (the app takes a long time to download on a slow connection).
  local before
  before=$(ls "$HOME"/sapoche-release-"$abi"-*.apk 2>/dev/null | grep -v -- "-$NAME.apk" | sort -V | tail -1 || true)
  if [ -n "$before" ] && [ "$SIZE_OK" = 0 ] && [ "$SIZE" -gt $(( $(stat -c %s "$before") + 200000 )) ]; then
    echo "the $abi APK is $(( SIZE - $(stat -c %s "$before") )) bytes bigger than $(basename "$before"); run again with --size-ok if that is meant"; exit 1
  fi
  gzip -9 -n -c "$OUT" > "$OUT.gz"
  GZSIZE=$(stat -c %s "$OUT.gz")
}

# A 32-bit phone that is let install the 64-bit APK crashes when the app opens (no libflutter.so for it), and the other way
# round the app cannot start at all: an APK must carry the native code of its own kind of phone and of no other
check_abi() {
  local apk=$1 lib=$2 libs
  libs=$(unzip -Z1 "$apk" 'lib/*')
  echo "$libs" | grep -qx "lib/$lib/libflutter.so" || { echo "$(basename "$apk") has no lib/$lib/libflutter.so"; exit 1; }
  if echo "$libs" | grep -v "^lib/$lib/" | grep -q .; then
    echo "$(basename "$apk") holds native code of another kind of phone:"; echo "$libs" | grep -v "^lib/$lib/"; exit 1
  fi
}

build_apk arm64 android-arm64 arm64-v8a
OUT64=$OUT; SHA64=$SHA; SIZE64=$SIZE; GZSIZE64=$GZSIZE
build_apk arm32 android-arm armeabi-v7a
OUT32=$OUT; SHA32=$SHA; SIZE32=$SIZE; GZSIZE32=$GZSIZE
OUT=$OUT64; SHA=$SHA64; SIZE=$SIZE64; GZSIZE=$GZSIZE64
LATEST=$(dirname "$OUT")/sapoche-latest-$NAME.json
python3 - "$LATEST" "$CODE" "$NAME" "$SHA" "$SIZE" "$GZSIZE" "$SHA32" "$SIZE32" "$GZSIZE32" "$APP/release-notes" "${NOTES_ARGS[@]+"${NOTES_ARGS[@]}"}" <<'PY'
import json, os, sys
path, code, name, sha, size, gz_size, sha32, size32, gz_size32, folder, *lines = sys.argv[1:]

def read(file):
    full = os.path.join(folder, file)
    return open(full, encoding="utf-8").read().strip() if os.path.exists(full) else ""

notes = "\n".join(lines).strip() or read(f"{name}.txt")
notes_vi = read(f"{name}.vi.txt")
latest = {"versionCode": int(code), "versionName": name, "sha256": sha, "size": int(size), "file": f"sapoche-{name}.apk", "gzFile": f"sapoche-{name}.apk.gz", "gzSize": int(gz_size), "notes": notes}
# The file of the phones with a 32-bit Android (they cannot run the one above); a phone that does not know this field
# is a 64-bit one. Only added: older apps read the rest as before.
latest["arm32"] = {"sha256": sha32, "size": int(size32), "file": f"sapoche-{name}-arm32.apk", "gzFile": f"sapoche-{name}-arm32.apk.gz", "gzSize": int(gz_size32)}
if notes_vi:
    latest["notesVi"] = notes_vi
# The notes of the last few versions too, so that a phone that is several versions behind can read all it has missed
# (the notes inside the app stop at the version it was built as)
def number(version):
    return [int(part) for part in version.split(".")]

versions = sorted(
    (f[:-4] for f in os.listdir(folder) if f.endswith(".txt") and not f.endswith(".vi.txt") and f[:-4].replace(".", "").isdigit()),
    key=number,
    reverse=True,
)
history = []
for version in versions:
    if number(version) > number(name):
        continue
    entry = {"version": version, "notes": notes if version == name else read(f"{version}.txt")}
    vi = notes_vi if version == name else read(f"{version}.vi.txt")
    if vi:
        entry["notesVi"] = vi
    history.append(entry)
latest["history"] = history[:10]
if not notes:
    print(f"warning: no release notes for {name} (app/release-notes/{name}.txt)", file=sys.stderr)
json.dump(latest, open(path, "w"), ensure_ascii=False)
PY
echo "built $OUT ($SIZE bytes, $GZSIZE gzipped, sha256 $SHA)"
echo "built $OUT32 ($SIZE32 bytes, $GZSIZE32 gzipped, sha256 $SHA32)"

if [ "$PUBLISH" = 1 ]; then
  # A phone never goes back to a lower build number, so a release that crashes at launch must not leave this computer.
  # The emulator runs x86_64 only, so the same code is built once more for it.
  "$FLUTTER" build apk --release --target-platform android-x64 "${SHRINK[@]}"
  SMOKE_APK=$HOME/sapoche-release-x64-$NAME.apk
  cp build/app/outputs/flutter-apk/app-release.apk "$SMOKE_APK"
  "$APP/tool/smoke.sh" "$SMOKE_APK"
  # The copy for GitHub, which anybody can download: the same code, signed the same, with no key inside (SAPOCHE_NO_KEY).
  # It is given its key by a setup link. The key must not be anywhere in it, which is checked before it can leave.
  PUBLIC_APK=$HOME/sapoche-$NAME-android.apk
  PUBLIC_APK32=$HOME/sapoche-$NAME-android-arm32.apk
  SAPOCHE_NO_KEY=1 "$FLUTTER" build apk --release --target-platform android-arm64 --split-debug-info="$SYMBOLS/public" --obfuscate
  cp build/app/outputs/flutter-apk/app-release.apk "$PUBLIC_APK"
  SAPOCHE_NO_KEY=1 "$FLUTTER" build apk --release --target-platform android-arm --split-debug-info="$SYMBOLS/public" --obfuscate
  cp build/app/outputs/flutter-apk/app-release.apk "$PUBLIC_APK32"
  check_abi "$PUBLIC_APK" arm64-v8a
  check_abi "$PUBLIC_APK32" armeabi-v7a
  KEY=$(sed -n 's/^sapoche\.roomKey=//p' "$APP/android/sapoche.properties")
  if [ -n "$KEY" ]; then
    for apk in "$OUT64" "$OUT32" "$PUBLIC_APK" "$PUBLIC_APK32"; do
      found=0
      for dex in $(unzip -Z1 "$apk" 'classes*.dex'); do
        # Not grep -q: it stops at the first match, unzip then dies of SIGPIPE and pipefail calls the whole line a failure
        unzip -p "$apk" "$dex" | grep -aF -- "$KEY" >/dev/null && found=1
      done
      case "$apk" in
        "$OUT64"|"$OUT32") [ "$found" = 0 ] && { echo "the check for the key does not find it in $(basename "$apk"), which has it: it cannot be trusted"; exit 1; } ;;
        *) [ "$found" = 1 ] && { echo "the key is inside $(basename "$apk"), made for GitHub: not published"; exit 1; } ;;
      esac
    done
  fi
  "$BUILD_TOOLS/apksigner" verify "$PUBLIC_APK" >/dev/null
  "$BUILD_TOOLS/apksigner" verify "$PUBLIC_APK32" >/dev/null
  cd "$SERVER"
  npx wrangler r2 object put "sapoche-releases/sapoche-$NAME.apk" --remote --file "$OUT" --content-type application/vnd.android.package-archive
  npx wrangler r2 object put "sapoche-releases/sapoche-$NAME.apk.gz" --remote --file "$OUT.gz" --content-type application/gzip
  npx wrangler r2 object put "sapoche-releases/sapoche-$NAME-arm32.apk" --remote --file "$OUT32" --content-type application/vnd.android.package-archive
  npx wrangler r2 object put "sapoche-releases/sapoche-$NAME-arm32.apk.gz" --remote --file "$OUT32.gz" --content-type application/gzip
  npx wrangler r2 object put "sapoche-releases/latest.json" --remote --file "$LATEST" --content-type application/json
  echo "published $NAME ($CODE)"
  # Also on the release of this repository (tag v<version>), beside the iPhone build the CI puts there. Not having the
  # token is not a failure: the release above is complete without it.
  status=0
  "$APP/tool/github_release.py" "v$NAME" "$APP/release-notes/$NAME.txt" "$PUBLIC_APK" "$PUBLIC_APK32" || status=$?
  [ "$status" = 3 ] && echo "NOT on GitHub: see app/tool/github_release.py for the token" || [ "$status" = 0 ] || exit "$status"
else
  echo "not published; run again with --publish to put it in the bucket"
fi
