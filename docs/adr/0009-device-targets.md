# ADR-0009 — Device and platform targets

**Status:** Accepted · **Date:** 2026-08-09

## Context

"Congo, meaning under-developed country" — the brief is explicit. The realistic device is an Android Go phone, 2 GB RAM, 720p screen, quad-core A53, 8–32 GB storage that is usually nearly full, on prepaid data. Many are second-hand. Some conductors have devices with cracked digitisers.

An app that only performs on a mid-range Android is a product failure here, not a performance nit.

## Decision

### Android

- **minSdk 21 (Android 5.0 Lollipop).** Flutter's own floor. Covers effectively the entire installed base in this market. Going to 23 or 24 would be easier and buys us nothing users would notice.
- **targetSdk / compileSdk:** latest stable, as Play requires.
- **Distribution:** Android App Bundle on Play, **plus a per-ABI split APK** hosted for direct download and for sideloading via agencies. Play Store access is not universal; agents will install the app for customers from a local file. This is a real distribution channel here, not a fallback.
- **Budget: ≤ 15 MB per-ABI APK, ≤ 2.5 s cold start on a 2 GB Android 10 device.** Both enforced in CI; a PR that regresses either fails.

### iOS

- **iOS 13+.** Diaspora and higher-income users. Not the volume market, but the brief asks for it and the incremental cost on Flutter is small.

### Engineering constraints that follow

| Constraint | Rule |
|---|---|
| **Renderer** | Impeller (default, ~22% better frame times than Skia on budget Android). |
| **Memory** | Low-end devices die of memory, not CPU. No unbounded lists, no retained images, `dispose()` audited in review. Memory profiled on a real 2 GB device before each release. |
| **Images** | No network images above 20 KB. `cacheWidth`/`cacheHeight` always set. Operator logos are bundled SVG/vector, not fetched PNGs. |
| **Fonts** | One family, subset to Latin + French diacritics. Bundled — never fetched at runtime. Saves ~400 KB and a network round trip. |
| **Animation** | Nothing over 300 ms. No continuous/looping animation. Respect `disableAnimations`. Fancy motion is a battery and jank tax paid by the poorest users. |
| **Rebuilds** | `const` constructors mandatory (lint-enforced), `select`-scoped watches on lists. |
| **Packages** | Every dependency is a size and risk liability. Adding one requires a note in the PR describing what it costs in KB and why we cannot write it in 100 lines. |
| **Permissions** | Camera (scanning), storage (ticket export) only. No contacts, no location at launch. Every permission request is a conversion loss and a trust question. |

### Testing matrix

CI runs golden and integration tests on an emulator profile matching **2 GB RAM / Android 10 / 720p**. That is the reference device, not a Pixel. Before each release, manual smoke test on a physical low-end handset — profile mode, on device, never the simulator.

## Consequences

We will say no to things. Rich illustrations, Lottie animations, video onboarding, heavy chart libraries in the console-on-mobile — all rejected by default. The design system (ADR-0010) is built from this constraint rather than apologising for it: flat colour, vector shapes, type and space do the work. That is also why it will look good.
