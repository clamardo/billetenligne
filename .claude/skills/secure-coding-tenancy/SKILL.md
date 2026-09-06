---
name: secure-coding-tenancy
description: Apply BilletEnLigne security invariants when changing authentication, company permissions, traveller privacy, boarding, payments, uploads, or user input in the Dart API and Flutter apps.
---

# Secure coding for BilletEnLigne

Use [tenant-isolation](../tenant-isolation/SKILL.md) for any company-owned data.
A company is an operator, identified by `operators.id` / `operator_id`. Market selection,
station scope and the currently displayed Flutter app do not establish company authority.

## Identity and authorization

- Follow `services/api/lib/src/adapters/firebase_auth_gateway.dart` and the identity
  adapter: verified identity is combined with current server-side memberships. An
  unaccepted/revoked membership or inactive operator must not grant console authority.
- Preserve `/public`, `/console`, and `/admin` authorization boundaries and their distinct
  database scopes. Gate operations with capabilities from `ports/capability.dart` and
  `middleware/require.dart`; hiding a Flutter control is not authorization.
- Station restrictions and conductor departure assignment must be checked on the resource
  being used. Empty station lists currently mean unrestricted access in `TenantScope`;
  do not assume an unconfigured vendor is automatically denied.
- Resolve platform roles server-side and preserve reasons/audit records on platform actions.
  Do not claim separate Firebase realms, mandatory MFA everywhere, or independent database
  credentials merely because an ADR requests them; inspect the actual enforcement.

## Traveller and ticket privacy

Purchaser identity, passenger identity, operator staff, and a trip-share follower are
different authorities. A public share must not reveal passenger details. Ticket-link
claims must preserve ownership and step-up checks; knowledge of a booking reference or
company UUID alone must not grant access. Use existing anti-enumeration responses and
rate limits when changing sign-in, onboarding, recovery, and bearer-link lookups.

Preserve Ed25519 verification, departure binding, void/redeem checks and duplicate-scan
handling. Test offline replay under the original authorized company/departure; changing
accounts must not expose the previous account's cached manifests or credentials.

## Money and asynchronous actions

Use integer minor units and explicit currency. Derive quotes and ownership server-side.
Preserve holds, atomic inventory updates, idempotency, captured-payment requirements for
tickets, refund policy versions and append-only balanced ledger entries. Callbacks must
verify their provider authentication and bind provider references to the persisted payment,
booking and company. Duplicate or late callbacks must not issue tickets or money twice.

Do not broaden platform/worker authority to simplify a traveller or console operation.
For legitimate rescue/protection transfers, validate both companies and disclose only the
fields needed by the authorized participants.

## Files, configuration and validation

Validate input at the application boundary and map failures through existing domain/API
error contracts. Bound strings, collections, uploads and enum values. Parameterize SQL.
Validate file type/size and ownership before upload completion or signed downloads; object
keys and cached URLs must not allow company substitution. Keep KYB documents private.

Use the existing environment/configuration adapters and secure store. Never commit or log
credentials, OTPs, TOTP seeds, ticket secrets, full payment payloads or passenger records.
Preserve production refusal of demo signing keys and fake authentication. Error responses
must not contain raw database errors or another company's identifiers.

## Verification

Read the matching ADRs: 0007 ticket security, 0011 tenancy, 0013 identity, 0018 Firebase,
0023 public sales, and feature-specific payment/boarding decisions. Trace the executing
implementation where design and code disagree. Add denial tests with two companies and
two travellers, then follow [regression-check](../regression-check/SKILL.md). Report
unverified paths and known gaps without calling the system fully isolated.
