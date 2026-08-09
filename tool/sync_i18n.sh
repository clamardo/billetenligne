#!/usr/bin/env bash
# Copies the translation catalog into each Flutter app's asset bundle.
#
# `bel_localization` is a **pure Dart** package: the Dart Frog API and the
# workers import it, and adding a Flutter dependency so it could declare
# `flutter: assets:` would break the server build. Flutter, for its part,
# refuses asset paths containing `..`.
#
# So the YAML is copied. The catalog in `packages/bel_localization/i18n` stays
# the single source — one reviewed French sentence, every surface — and
# `i18n_freshness_test.dart` in each app fails the build if a copy has drifted
# from it. A stale copy is the failure mode worth guarding: it ships an app
# whose strings quietly disagree with the server's.
#
#   ./tool/sync_i18n.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/packages/bel_localization/i18n"

for app in "$ROOT"/apps/*/; do
  [[ -f "$app/pubspec.yaml" ]] || continue
  grep -q 'bel_localization' "$app/pubspec.yaml" || continue

  target="$app/assets/i18n"
  rm -rf "$target"
  mkdir -p "$target"
  cp -R "$SOURCE/." "$target/"
  printf '   %-28s <- packages/bel_localization/i18n\n' \
    "$(basename "$app")/assets/i18n"
done

printf '\033[32m── catalog synced\033[0m\n'
