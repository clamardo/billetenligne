# Kilo artwork

Every illustration, pattern and hero in the product lives here as an SVG you
can open in Figma, Illustrator or a text editor. Nothing is drawn in Dart.

## Theming

Flat illustration sets go stale the moment the product grows a dark mode:
artwork drawn in fixed colours either glows on a dark page or has to be
duplicated per theme. Kilo's artwork is drawn against a **sentinel palette**
instead — eight impossible magenta values that are substituted for real tokens
at paint time, so one file renders correctly in light, dark and plein soleil.

Use only these fills and strokes:

`#FF00E0` — ink, the line work            (`contentPrimary`)
`#FF00E1` — muted, secondary line work    (`contentSecondary`)
`#FF00E2` — brand                         (`brandPrimary`)
`#FF00E3` — brand wash, large soft shapes (`brandPrimarySoft`)
`#FF00E4` — accent                        (`brandAccent`)
`#FF00E5` — accent wash                   (`brandAccentSoft`)
`#FF00E6` — surface, knock-outs           (`surfaceRaised`)
`#FF00E7` — hairline                      (`borderSubtle`)

`none` and `currentColor` are also allowed. Any other literal colour fails
`test/art_test.dart` — that is deliberate, because a single stray `#333` is
invisible in review and unreadable in dark mode.

## After editing

```sh
dart run tool/build_art.dart
```

This regenerates `lib/src/art/kilo_art.g.dart`, which embeds each file as a
string constant. The artwork is compiled in rather than loaded from the asset
bundle so it paints synchronously — an empty state that flashes blank before
its illustration arrives is worse than no illustration. `art_test.dart` fails
if the generated file has drifted from this folder.

## Licence

All artwork here is original to BilletEnLigne.
