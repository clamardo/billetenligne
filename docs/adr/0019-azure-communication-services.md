# ADR-0019 — Azure Communication Services for SMS and email

**Status:** Accepted · **Date:** 2026-08-09 · **Related:** ADR-0013, ADR-0018, ADR-0020

## Context

SMS is not a nice-to-have in this market — it is the trust anchor (`01-feature-spec.md` §12). A traveller who is unsure whether the app "really" worked will believe the SMS. Every money event and every disruption goes out on it, and a failure to deliver is indistinguishable, from the traveller's side, from us having taken their money and vanished.

Email matters far less to travellers and far more to operators: statements, invoices, KYB correspondence, onboarding.

The CogitovaSchool platform already uses **Azure Communication Services** with an established configuration shape: a connection string and a sender address supplied from the environment, passed to every host that sends, and **blank is a supported state** that falls back to a logging sender.

## Decision

**Azure Communication Services for both SMS and transactional email**, behind one port, following the CogitovaSchool configuration pattern exactly.

```dart
abstract interface class NotificationGateway {
  Future<Result<Receipt, NotifyFailure>> sms(SmsMessage m);
  Future<Result<Receipt, NotifyFailure>> email(EmailMessage m);
}
```

Adapters: `AcsNotificationGateway` (production and shared dev), `LoggingNotificationGateway` (no connection string configured), `FakeNotificationGateway` (tests — records everything, asserts on it).

### Configuration — deliberately identical to CogitovaSchool

| Variable | Meaning |
|---|---|
| `COMMS__CONNECTIONSTRING` | ACS connection string. **Blank is valid** and selects the logging sender. |
| `COMMS__SMSFROM` | Provisioned sender number or alphanumeric sender id |
| `COMMS__EMAILFROM` | Verified sender address |

Blank-is-valid is the important property: a new developer clones the repo and everything runs, writing messages to the log instead of a real handset. Nobody's phone gets an SMS from someone else's laptop, and no test run costs money.

**We reuse the existing CogitovaSchool ACS resource for early development**, as agreed, and provision a dedicated BilletEnLigne resource before any real traffic. The connection string is never committed — it comes from the developer's own environment, exactly as it does today.

### Rules

1. **Every message goes through the outbox** (ADR-0003). Compose → persist → drain. A send is never inline with a request, so a slow SMS gateway can never slow down a payment confirmation.
2. **Idempotent per event.** `(eventId, channel, recipient)` is unique. A retried drain cannot double-send. Nothing erodes trust like two conflicting SMS about one payment.
3. **Templates come from the shared YAML catalog** (ADR-0008), rendered server-side in the *recipient's* stored language. The server is the only place that renders prose, and this is why.
4. **SMS length is a build gate.** Templates over 160 characters fail a test — a multipart SMS costs a multiple, and at Congolese volumes that is a real line item. Already enforced in `bel_localization`'s test suite.
5. **Delivery receipts are ingested and measured.** Delivery rate **per operator, per hour** is a first-class dashboard, because this is exactly the kind of dependency that degrades silently.
6. **Quiet hours 22:00–06:00** for everything except money and departure-critical events. A 03:00 SMS about a cancelled 05:00 departure is precisely what the passenger wants.
7. **Channel fallback is explicit:** push first where a device token exists, SMS always for money and disruption, email for operators. Never "SMS only if push failed" — for money, both fire.

### Relationship to Firebase Auth

Firebase sends the **login OTP** (ADR-0018). ACS sends **everything else**. Two SMS senders is a real inconsistency and we accept it deliberately: Firebase's OTP path is battle-tested and we do not want to own it.

If Firebase OTP deliverability proves weak on Airtel/MTN Congo, the documented fallback in ADR-0018 collapses this — we send the OTP over ACS and mint a Firebase custom token, and then **all** SMS goes out on one route we control and measure. Build the ACS OTP path early enough to have the option.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Local Congolese SMS aggregator** | Probably better deliverability and price on Airtel/MTN, and worth a live A/B before scale. Rejected as the starting point: unknown reliability, unknown API quality, and nothing in-house to compare against. The port makes switching cheap. |
| **Twilio** | Excellent API, strong global coverage, higher cost per message. A credible second source. |
| **Firebase Cloud Messaging for everything** | Push only. Does not reach a feature phone or a user who uninstalled. Rejected as a replacement; kept as the push channel. |
| **Email-first** | Misreads the market entirely. Rejected. |

## Consequences

One more cloud dependency, and one that costs per message — so the outbox, the length gate and the quiet hours are cost controls as much as UX rules. Monitoring delivery rate by operator is not optional: a silent 30% drop on one network would look, to us, exactly like a drop in conversion.
