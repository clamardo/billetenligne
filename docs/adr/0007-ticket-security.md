# ADR-0007 — Signed, offline-verifiable tickets

**Status:** Accepted · **Date:** 2026-08-09

## Context

A conductor boards ~60 passengers in ~10 minutes at a roadside stop that may have no data coverage. Verification must be **offline, under 2 seconds, and resistant to the obvious attack: screenshotting a friend's QR code.**

A QR code containing a booking reference that the conductor's app looks up in a database fails the offline requirement. A QR containing a raw booking reference with no signature fails the forgery requirement.

## Decision

The ticket QR carries a **self-contained signed payload**. Verification is a local cryptographic check plus a local redemption log. No network required.

### Payload

CBOR-encoded, **Ed25519**-signed, base45-encoded, rendered as a QR at error-correction level M. Target: **under 300 bytes** so the QR stays low-density and scans fast on a cracked screen in daylight.

```
{
  v:  1,                    schema version
  t:  "BEL",                issuer
  b:  "7QK4M2",             booking ref (short, human-readable, Crockford base32)
  s:  "12A",                seat label
  d:  1754870400,           departure epoch
  r:  "BZV>PNR",            route code
  o:  "ODN",                operator code
  p:  "Aline M.",           passenger name (truncated)
  k:  2                     key id
}
+ 64-byte Ed25519 signature
```

Ed25519 over ECDSA: 64-byte signatures, fast verification on weak ARM cores, no curve-parameter footguns.

### Key management

- Signing key lives **only** in the server's KMS/HSM. Never on any device.
- Devices carry **public** keys only. Key set is fetched at login and refreshed on every sync; `k` selects the key so rotation is seamless.
- Rotation quarterly, and immediately on any suspected compromise. Old public keys are retained until the last ticket signed with them has departed.

**As built, and the gap named.** There is no KMS. The seed comes from `TICKETS__SIGNINGSEED` — 32 bytes of base64, injected as a Kubernetes secret, held in the process for as long as it runs. That is weaker than this section describes: an operator with cluster access can read it, and the key exists in memory rather than behind an API that only ever signs.

What has been closed is worse than that gap and was live: the seed was a **literal in the adapter**, handed to the database composition as readily as to the fakes, so a deployment would have signed real tickets with 32 bytes printed in a public repository. Anybody who could read the source could have minted a ticket for any seat on any coach, and the scanner would have gone green on it. A process talking to a real database now refuses to start without a configured seed, and refuses the development one by value — `BEL__ENV=development` is the only way to reach it, which `infra/dev/.env` sets and no deployment does.

Moving to a KMS changes one file (`infrastructure/config/ticket_signing_key.dart`) and the shape of `Ed25519TicketSigner`, which already selects by key id — the wire format has carried `k` since the first ticket, so rotation does not need the app to change.

### Anti-replay — the part that actually matters

A signature proves authenticity, not single use. Screenshots are the real threat.

1. **Local redemption log.** On scan, the conductor's device records `(booking_ref, seat, timestamp, device_id)` in local SQLite. A second scan of the same ticket on the same device shows a loud red **"DÉJÀ EMBARQUÉ — 08:42"** with the first scan time.
2. **Manifest pre-load.** When the conductor opens a departure, the device downloads that departure's manifest (a few KB). Cross-device double-boarding within one departure is caught because the manifest carries any redemptions already synced.
3. **Rotating display code.** The traveller's app shows, under the QR, a **6-digit code that changes every 30 seconds**, derived as `TOTP(HMAC(ticket_secret, time_window))`. The conductor's app computes the expected value offline and flags a mismatch. A screenshot's code is frozen and therefore stale — this is what kills the screenshot attack. A screenshot still *scans*, but it fails the freshness check.
4. **Degraded mode.** If the traveller's phone is dead, the conductor looks up the booking reference against the offline manifest and boards manually with an explicit "manual boarding" record. Never leave a paying passenger at the roadside because of our technology.
5. **Redemptions sync opportunistically** through the outbox (ADR-0003) whenever the device sees a network, and back-fill the central manifest.

### Printable ticket

A4 and 80 mm thermal, generated **client-side** so it works offline. Carries the same QR, booking reference, rotating-code *fallback* (a static long-lived backup code, rate-limited and flagged in the console when used), route, seat, departure, operator, and boarding instructions in the user's language. Printing is via the OS share/print sheet — no printer drivers, no bespoke integration.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Server lookup by reference** | Fails offline. Rejected. |
| **JWT in the QR** | JSON + base64 pushes past 500 bytes and JWT's algorithm agility (`alg: none`) is a liability. Rejected. |
| **Signature only, no freshness code** | Screenshot attack works. Rejected. |
| **NFC / BLE handshake** | Robust, but assumes hardware the target devices do not reliably have. Rejected. |
| **EU DCC / IATA BCBP formats** | Studied for lessons — CBOR + COSE + base45 + Ed25519 is lifted directly from the EU Digital COVID Certificate design, which solved exactly this problem (offline verification, cheap devices, hostile conditions) at continental scale. We follow its shape without its baggage. |

## Consequences

Cryptography in the app means a security review before launch is mandatory, not optional. The rotating code adds a clock-skew dependency: the conductor app tolerates ±90 s and warns when device time looks wrong. Ticket transfer to another person becomes a deliberate server-side re-issue (new signature), which is correct — it gives us a reason to know who is actually travelling.
