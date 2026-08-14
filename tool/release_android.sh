#!/usr/bin/env bash
# Builds the Android artifacts a person can actually install, and checks them.
#
#   BEL_API_URL=https://blt.cg ./tool/release_android.sh
#   ./tool/release_android.sh --keystore        # make a throwaway upload key
#   ./tool/release_android.sh --bundle          # also build .aab for Play
#   ./tool/release_android.sh --app scanner     # one app instead of both
#
# **Two artifacts, for two ways of getting the app onto a handset.** The `.aab`
# is what Play takes; per-ABI `.apk` files are what an agency sideloads, and
# the split is not tidiness — a universal APK carries three copies of the
# engine, and the difference is tens of megabytes over a connection somebody
# is paying for by the megabyte.
#
# **Building is not the check.** A release APK differs from every debug build
# in ways nothing else in this repository exercises: a different manifest
# merge, a different signing certificate, a different set of `--dart-define`s
# baked in and unchangeable. All three have shipped broken here, so each
# artifact is opened and interrogated after it is built: the permission that
# only the debug manifest declared, the certificate the template signs release
# builds with, the server address the bundle was compiled against.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS=(traveller scanner)
BUNDLE=0
KEYSTORE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)   BUNDLE=1 ;;
    --keystore) KEYSTORE=1 ;;
    --app)      shift; APPS=("$1") ;;
    *) echo "unknown argument: $1"; exit 64 ;;
  esac
  shift
done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
die()   { red "── $*"; exit 1; }

TOOLS="$(ls -d "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"/build-tools/* 2>/dev/null | sort -V | tail -1)"
[[ -n "$TOOLS" ]] || die "no Android build-tools — set ANDROID_HOME"
AAPT="$TOOLS/aapt2"
APKSIGNER="$TOOLS/apksigner"

# A key nobody publishes with, so the checks below have something to check.
# Deliberately generated rather than committed: a keystore in a repository is
# a keystore everybody has, which is the exact property that makes the debug
# key unusable.
if [[ "$KEYSTORE" == 1 ]]; then
  pass="${BEL_KEYSTORE_PASSWORD:-placeholder-not-for-publication}"
  for app in "${APPS[@]}"; do
    dir="$HERE/apps/$app/android"
    store="$dir/upload-keystore.jks"
    if [[ -f "$store" ]]; then echo "── $app already has a key"; continue; fi
    keytool -genkeypair -v -keystore "$store" -storetype PKCS12 \
      -keyalg RSA -keysize 4096 -validity 10000 -alias upload \
      -storepass "$pass" -keypass "$pass" \
      -dname "CN=BilletEnLigne placeholder, O=BilletEnLigne, C=CG" >/dev/null
    cat > "$dir/key.properties" <<EOF
storeFile=upload-keystore.jks
storePassword=$pass
keyAlias=upload
keyPassword=$pass
EOF
    green "── $app: throwaway upload key written to $store"
  done
  exit 0
fi

: "${BEL_API_URL:?set BEL_API_URL — the address these builds will call}"
if [[ -z "${BEL_FIREBASE_EMULATOR:-}" && -z "${BEL_FIREBASE_API_KEY:-}" ]]; then
  die "set BEL_FIREBASE_API_KEY, or BEL_FIREBASE_EMULATOR for a local build"
fi

# The host whose `/.well-known/assetlinks.json` must name this app. Taken from
# the API address by default, because those are the same deployment and
# keeping them in step by hand is how a staging build ends up claiming
# production's links.
LINK_HOST="${BEL_LINK_HOST:-$(printf '%s' "$BEL_API_URL" | sed -e 's#^[a-z]*://##' -e 's#[:/].*##')}"
# Room for the ABI offset. `--split-per-abi` does not ship the build number
# you gave it: Flutter's Gradle plugin adds a thousand per architecture, so one
# build becomes versionCodes N+1000, N+2000 and N+4000. With the commit count
# as N that overlaps — commit 1149's armeabi-v7a APK and commit 149's
# arm64-v8a APK are both 2149, and Play refuses a versionCode a package has
# already used, which is a rejection at upload with nothing wrong in the tree.
# Multiplying leaves four digits of room, and every code stays distinct
# forever.
BUILD_NUMBER="${BEL_BUILD_NUMBER:-$(( $(git -C "$HERE" rev-list --count HEAD 2>/dev/null || echo 1) * 10000 ))}"

echo "── against $BEL_API_URL · links on $LINK_HOST · build $BUILD_NUMBER"

defines=(
  --dart-define=BEL_API_URL="$BEL_API_URL"
  --dart-define=BEL_FIREBASE_EMULATOR="${BEL_FIREBASE_EMULATOR:-}"
  --dart-define=BEL_FIREBASE_PROJECT="${BEL_FIREBASE_PROJECT:-demo-billetenligne}"
  --dart-define=BEL_FIREBASE_API_KEY="${BEL_FIREBASE_API_KEY:-}"
)

for app in "${APPS[@]}"; do
  dir="$HERE/apps/$app"
  package="cg.billetenligne.bel_$app"
  [[ -d "$dir/android" ]] || die "$app has no android/ — it is a web surface"
  [[ -f "$dir/android/key.properties" ]] ||
    die "$app has no android/key.properties — run --keystore, or install the real one"

  echo "── building $app"
  (cd "$dir" && flutter build apk --release --split-per-abi \
    --build-number="$BUILD_NUMBER" \
    -P belLinkHost="$LINK_HOST" \
    "${defines[@]}" >/dev/null)

  if [[ "$BUNDLE" == 1 ]]; then
    echo "── bundling $app"
    (cd "$dir" && flutter build appbundle --release \
      --build-number="$BUILD_NUMBER" \
      -P belLinkHost="$LINK_HOST" \
      "${defines[@]}" >/dev/null)
  fi

  out="$dir/build/app/outputs/flutter-apk"
  shopt -s nullglob
  apks=("$out"/app-*-release.apk)
  shopt -u nullglob
  [[ ${#apks[@]} -ge 2 ]] || die "$app produced ${#apks[@]} per-ABI APKs"

  for apk in "${apks[@]}"; do
    badging="$("$AAPT" dump badging "$apk")"

    # The one that only the debug manifest declared. Everything else in this
    # loop is a check; this one is a scar.
    grep -q "uses-permission: name='android.permission.INTERNET'" <<<"$badging" ||
      die "$(basename "$apk") cannot open a socket — INTERNET is not in the release manifest"

    grep -q "package: name='$package'" <<<"$badging" ||
      die "$(basename "$apk") is not $package"
    case "$(basename "$apk")" in
      *armeabi-v7a*) offset=1000 ;;
      *arm64-v8a*)   offset=2000 ;;
      *x86_64*)      offset=4000 ;;
      *)             offset=0 ;;
    esac
    grep -q "versionCode='$(( BUILD_NUMBER + offset ))'" <<<"$badging" ||
      die "$(basename "$apk") is not versionCode $(( BUILD_NUMBER + offset ))"

    # An adaptive icon, which is an XML resource. The Flutter template's
    # default beachball is a plain PNG, so this is the check that says the
    # brand mark is still installed rather than reverted by a `flutter
    # create` somebody ran to fix something else.
    grep -qE "^application-icon-160:'res/.*\.xml'" <<<"$badging" ||
      die "$(basename "$apk") has no adaptive launcher icon"

    label="$(sed -n "s/^application-label:'\(.*\)'$/\1/p" <<<"$badging")"
    [[ -n "$label" && "$label" != bel_* ]] ||
      die "$(basename "$apk") is labelled '$label' — that is the package name, on a launcher"

    abis="$(grep -c "^native-code:" <<<"$badging" || true)"
    [[ "$abis" == 1 ]] || die "$(basename "$apk") carries $abis ABI lines"

    # The App Links claim, which `aapt2 dump badging` does not print — an
    # intent filter naming the wrong domain is invisible in every summary and
    # presents months later as links that open a browser.
    # Read whole, not piped into grep: `grep -q` closes the pipe on its first
    # match, aapt2 dies of SIGPIPE, and `set -o pipefail` then fails the check
    # **because it succeeded**.
    manifest="$("$AAPT" dump xmltree --file AndroidManifest.xml "$apk")"
    if grep -q 'autoVerify' <<<"$manifest"; then
      grep -q "android:host(0x01010028)=\"$LINK_HOST\"" <<<"$manifest" ||
        die "$(basename "$apk") claims links on a host that is not $LINK_HOST"
    fi

    certs="$("$APKSIGNER" verify --print-certs "$apk" 2>/dev/null)" ||
      die "$(basename "$apk") is not signed — there is no upload key on this machine"
    if grep -q 'CN=Android Debug' <<<"$certs"; then
      die "$(basename "$apk") is signed with the universal debug key — anybody can publish an update to it"
    fi
  done

  # Which certificate, in the form `/.well-known/assetlinks.json` wants it.
  # Printed rather than checked: until there is a Play listing there is
  # nothing to compare it against, and the fingerprint is the thing somebody
  # has to carry from this machine to `BEL__ANDROIDFINGERPRINTS`.
  digests="$("$APKSIGNER" verify --print-certs "${apks[0]}" 2>/dev/null)"
  fingerprint="$(sed -n 's/.*SHA-256 digest: \(.*\)/\1/p' <<<"$digests" |
    sed -n '1p' | tr 'a-f' 'A-F' | sed 's/\(..\)/\1:/g;s/:$//')"

  # The address is compiled into the snapshot and cannot be changed
  # afterwards, which is what makes a wrong one expensive: it is not a setting
  # somebody flips, it is a rebuild and a redistribution.
  arm64="$out/app-arm64-v8a-release.apk"
  if [[ -f "$arm64" ]]; then
    baked="$(unzip -p "$arm64" lib/arm64-v8a/libapp.so | strings | grep -cF "$BEL_API_URL" || true)"
    [[ "$baked" -gt 0 ]] ||
      die "$(basename "$arm64") was not compiled against $BEL_API_URL"
  fi

  for apk in "${apks[@]}"; do
    printf '   %-40s %s\n' "$(basename "$apk")" "$(du -h "$apk" | cut -f1)"
  done
  if [[ "$BUNDLE" == 1 ]]; then
    aab="$dir/build/app/outputs/bundle/release/app-release.aab"
    [[ -f "$aab" ]] || die "$app produced no bundle"
    printf '   %-40s %s\n' "$(basename "$aab")" "$(du -h "$aab" | cut -f1)"
  fi
  echo "   signed by SHA-256 $fingerprint"
done

green "── android release artifacts built and checked"
