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
# **The tree is flattened on the way in**, `pages/travel.yaml` becoming
# `fr__pages__travel.yaml`, and an `index.txt` is written beside it. That is
# not tidiness. A Flutter `assets:` entry names one directory and does not
# recurse, so the nested tree cost every app six pubspec lines *per language*
# and a hard-coded list of every file *per language* in its Dart. Adding
# Portuguese meant editing eight files that have nothing to do with
# Portuguese, and the day somebody edited seven of them the eighth shipped an
# app that silently could not read its own catalog. Flat, the whole bundle is
# one line — `- assets/i18n/` — in every app, forever, and the index is what
# the app enumerates instead of the file system.
#
# So: a new language is a folder here and a row in `languages.yaml`. Nothing
# else, in any app, ever.
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

  # The manifest keeps its name: it is the one file the app reads before it
  # knows what else there is to read.
  cp "$SOURCE/languages.yaml" "$target/languages.yaml"

  index="$target/index.txt"
  : >"$index"

  # Sorted, so the index is stable and a diff of it is a real change rather
  # than the order `find` happened to walk the disk in.
  while IFS= read -r file; do
    relative="${file#"$SOURCE"/}"
    [[ "$relative" == 'languages.yaml' ]] && continue
    flat="${relative//\//__}"
    cp "$file" "$target/$flat"
    printf '%s\n' "$relative" >>"$index"
  done < <(find "$SOURCE" -name '*.yaml' | sort)

  printf '   %-28s <- packages/bel_localization/i18n (%s files)\n' \
    "$(basename "$app")/assets/i18n" "$(wc -l <"$index")"
done

printf '\033[32m── catalog synced\033[0m\n'
