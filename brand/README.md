# Brand

The mark, the wordmark, and the four app icons.

## The mark

A **ticket stub with a journey inside it**. Two ideas in one shape: the notches
and the perforation say *ticket* with no text and in any language; the two nodes
and the rising line say *from here to there* — which is also, literally,
*kilomètre*.

Built from three primitives — rounded rectangle, circle, line — because it has
to survive everywhere it lives:

| Where | Size | Constraint it must pass |
|---|---|---|
| Favicon | 16 px | Notches still legible |
| Android adaptive icon | 108 dp | Inside the 66% safe zone, uncroppable |
| Ticket header | ~24 px | Prints beside a QR without competing |
| **Thermal ticket** | 80 mm, **1-bit** | `bel-mark-mono.svg` — outline, no fill to smear |
| Agency poster | A3 | Holds up with no raster artefacts |

```
brand/
├─ mark/
│  ├─ bel-mark.svg        colour, uses currentColor for the ticket body
│  └─ bel-mark-mono.svg   one-bit, outline — thermal printers
├─ wordmark/
│  └─ bel-wordmark.svg    horizontal lockup, for single-asset placements
└─ icons/
   ├─ traveller.svg  console.svg  scanner.svg  admin.svg
```

## The icon family

One silhouette, four grounds, four glyphs. **Colour is never the only
difference** — a cheap panel in sunlight flattens hues, and a colour-blind
conductor still has to pick the right app on a shared work phone.

| App | Ground | Inside the ticket | Why |
|---|---|---|---|
| **Traveller** | Forêt `#0A6B4F` | The journey — two nodes, a road | The primary brand, and the only one a traveller must recognise on a crowded home screen |
| **Boarding scanner** | Ink `#141A17` | A check, inside mint reticle corners | Deliberately the least brand-like icon in the family: a conductor must never hesitate between this and the passenger app |
| **Operator console** | Latérite `#D9772F` | A departure board — rows of times | The roads themselves; rows of times are what an operator looks at all day |
| **Admin back office** | Ardoise `#3B4650` | Control sliders | Restrained on purpose — an internal tool behind an IP allowlist and 2FA, not a product anyone markets |

## Rules

1. **Clear space** — one notch radius on every side. The notches are the
   identity; crowding them destroys it.
2. **Minimum size** — 16 px for the mark, 20 px for the lockup. Below that, use
   the mark alone.
3. **Never re-colour the ticket body.** It is `currentColor` so it inherits
   correctly on any ground; the route line takes the ground colour so the mark
   works as a knockout.
4. **Never add a gradient, a shadow or an outline glow.** The asset budget
   forbids it (ADR-0009) and it would not survive a thermal printer.
5. **Never stretch.** Scale uniformly.
6. **On an operator's accent colour**, use `bel-mark-mono.svg` in white. The
   eight accent hues are contrast-verified against white
   (`packages/bel_design/test/contrast_test.dart`).
7. **In live UI**, use the mark next to real Inter text rather than the
   wordmark SVG — the type then scales with the user's text-size setting.

## Adaptive icons

Android masks icons to whatever shape the launcher wants — circle, squircle,
teardrop. Everything meaningful sits inside the centre 66% (x/y 18..90 on the
108 canvas), so no mask can crop it. Foreground and background are supplied as
separate layers per `res/mipmap-anydpi-v26/`.
