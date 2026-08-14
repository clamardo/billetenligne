# BilletEnLigne — Reviews, end to end

**Status:** Specification and implementation roadmap · **Date:** 2026-08-14 · **Implements:** [ADR-0030](adr/0030-reviews.md) · **Governed by:** [ADR-0027](adr/0027-verticals-are-separate.md) · **Serves:** transport, rental, stays

## 0. What this document is

ADR-0030 decided what a review is, who may write one, what the platform will never do with them, and how the displayed score is computed. This says how to build it.

Four things to hold onto:

1. **`bel_reviews` never reads a vertical's tables.** Verticals push an eligibility row; the reviews package renders and stores what it was handed. If a `switch` on vertical ever appears in this package, the design has failed.
2. **The displayed score is never a plain mean.** §5 is arithmetic, not a preference, and the naive version has a known failure that a new listing learns to exploit in about a week.
3. **No score is shown below three reviews.** *"Nouveau"* and the texts.
4. **Reviews are never removed for money and never removed for being negative.** ADR-0030 §5 states these as commitments; §6 here is how the code makes them true rather than aspirational.

---

## 1. Current state

Nothing. `grep -ri 'review' --include=*.dart --include=*.sql .` matches only the operator-application *review queue*, which is a different thing entirely (`03-operator-lifecycle.md`) and must not be confused with it in naming.

To avoid exactly that collision: this subsystem is `bel_reviews`, schema `review`, routes under `/reviews/v1/`. The operator-application queue keeps every name it has.

---

## 2. The domain — `packages/bel_reviews`

Depends on `bel_platform` and nothing else.

```dart
/// What is being reviewed. A coach company, an airline and a rental company
/// are reviewed as operators; a hotel is reviewed as a property, because a
/// chain's two hotels are two different experiences.
///
/// Nothing smaller is reviewable. A rating of one coach or one room type is
/// noise: the sample per subject collapses and nobody chooses a hotel by
/// room-type rating.
enum ReviewSubjectKind { operator, property }

/// 1..5, whole stars only on input. Half stars exist in DISPLAY, as the
/// result of an average, and never as something a person can choose.
extension type const Stars._(int value) {
  factory Stars(int v) {
    if (v < 1 || v > 5) throw ArgumentError.value(v, 'stars', 'must be 1..5');
    return Stars._(v);
  }
}

final class Review {
  const Review({
    required this.id,
    required this.subjectKind,
    required this.subjectId,
    required this.authorDisplayName,   // "Aline M." — never more
    required this.stars,
    required this.createdAt,
    required this.state,
    this.subScores = const {},         // key -> Stars, all optional
    this.comment,
    this.language,
    this.editableUntil,
    this.reply,
  });
}

enum ReviewState { published, held, removed, withdrawn }
```

`held` is awaiting moderation, `removed` is a moderation decision, `withdrawn` is the author's own deletion. All three keep the row: a review is evidence in a dispute, and a vanished row takes the operator's reply with it.

### 2.1 Sub-scores are data, not an enum

```dart
/// The keys a given eligibility asks about. Supplied BY THE VERTICAL, stored
/// by key, translated from the catalog. `bel_reviews` never enumerates them
/// and never switches on them — that is the one property that keeps this
/// package free of vertical knowledge (ADR-0030 §5).
typedef SubScoreKeys = List<String>;
```

The keys each vertical supplies (ADR-0030 §2):

- transport — `ponctualite`, `confort`, `proprete`, `personnel`
- rental — `etat_vehicule`, `proprete`, `remise_cles`, `rapport_qualite_prix`
- stay — `proprete`, `emplacement`, `personnel`, `rapport_qualite_prix`, `electricite_wifi`

An unknown key that has no catalog entry renders as nothing rather than as a raw key. `./tool/sync_i18n.sh` plus a test over the union of the three lists is what stops that from happening in the first place.

### 2.2 The display name

```dart
/// "Aline Makaya" -> "Aline M." · "Jean-Pierre" -> "Jean-Pierre"
/// A single word is left alone; a name with no letters falls back to the
/// catalog's anonymous label rather than to an empty string.
String displayName(String fullName);
```

Never a full name, never a phone number, never a link to a profile. An operator can usually work out who wrote a review because they have the booking; the platform does not hand it to them, because a reviewer who is trivially identifiable self-censors (ADR-0030).

---

## 3. Schema

`infra/migrations/review/`, its own sequence, schema `review`, role `bel_reviews_app`. References `public.operators` and `public.user_accounts` and nothing else. Nothing in `public` references it (ADR-0027 §2).

### `review/0001_schema.sql` — schema, role, grants

### `review/0002_eligibility.sql`

```sql
-- The seam. A vertical writes one row when its service COMPLETES. The
-- reviews package never reads a vertical's tables and never learns what was
-- sold — same pattern as public.payables (ADR-0027 §3).
CREATE TABLE review.eligibilities (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Opaque to this package. Also the SMS link's identity, so somebody with
  -- no app and a feature phone can review from a text message (ADR-0026's
  -- reasoning, applied again).
  token         TEXT NOT NULL UNIQUE,
  subject_kind  TEXT NOT NULL,
  subject_id    UUID NOT NULL,
  operator_id   UUID NOT NULL REFERENCES public.operators(id) ON DELETE CASCADE,
  author_user_id UUID REFERENCES public.user_accounts(id),
  author_name   TEXT NOT NULL,
  -- The vertical's own reference, echoed nowhere and joined on never. Here
  -- only so an operator dispute can be traced by a human.
  source_kind   TEXT NOT NULL,          -- 'transport' | 'rental' | 'stay'
  source_ref    TEXT NOT NULL,
  sub_score_keys TEXT[] NOT NULL DEFAULT '{}',
  completed_at  TIMESTAMPTZ NOT NULL,
  expires_at    TIMESTAMPTZ NOT NULL,
  used_at       TIMESTAMPTZ,

  CONSTRAINT eligibilities_subject_kind_known
    CHECK (subject_kind IN ('operator','property')),
  CONSTRAINT eligibilities_source_kind_known
    CHECK (source_kind IN ('transport','rental','stay')),
  -- One review per booking. THE rule, in the schema rather than in a
  -- service, because it is the only thing making any of this worth reading.
  UNIQUE (source_kind, source_ref)
);
```

### `review/0003_reviews.sql`

`reviews` — `id`, `eligibility_id` (unique), `subject_kind`, `subject_id`, `operator_id`, `author_display_name`, `stars` with `CHECK BETWEEN 1 AND 5`, `sub_scores JSONB`, `comment TEXT` with `CHECK (char_length(comment) <= 1000)`, `language`, `state`, `held_reason`, `created_at`, `editable_until`, `updated_at`, `removed_at`, `removed_by`, `removed_reason`.

`replies` — `review_id` **unique** (one reply, enforced by the schema), `operator_id`, `body` with a 1000-character check, `author_staff_id`, `created_at`. No `updated_at`: a reply is not editable either, which is the symmetric half of the review not being editable by the operator.

`reports` — `review_id`, `reporter_user_id` nullable, `reason`, `note`, `created_at`, `resolved_at`, `resolved_by`, `resolution`.

### `review/0004_aggregates.sql`

```sql
CREATE TABLE review.aggregates (
  subject_kind   TEXT NOT NULL,
  subject_id     UUID NOT NULL,
  review_count   INTEGER NOT NULL DEFAULT 0,
  mean_x100      INTEGER NOT NULL DEFAULT 0,  -- integers, not floats
  shrunk_x100    INTEGER NOT NULL DEFAULT 0,
  sub_means      JSONB NOT NULL DEFAULT '{}',
  count_12m      INTEGER NOT NULL DEFAULT 0,
  mean_12m_x100  INTEGER NOT NULL DEFAULT 0,
  computed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (subject_kind, subject_id)
);
```

Ratings are stored as hundredths in integers. The same reasoning `Money` uses: a float mean that rounds differently on two platforms is a rating that disagrees with itself between the app and the console.

---

## 4. The eligibility seam

Each vertical writes one row at the moment its service completes, and never before:

- **Transport** — when a ticket is redeemed at the door. Not at departure, and not at booking: a review of a coach somebody did not board is a review of nothing.
- **Rental** — when the return condition report is accepted.
- **Stay** — the morning after the checkout date, which is when people have an opinion and before they have forgotten.

Written by `services/worker`, in the same transaction as the completion event where one exists, so a completed service always becomes reviewable exactly once.

The invitation goes out as SMS and email with the token link, once, 2 hours after the eligibility is created for transport and rental, and at 10:00 local the morning after checkout for stays. One reminder at day 3 if unused. Then silence — a third request is a nuisance and lowers the response rate rather than raising it.

The token is the identity, so no account is required. Someone who bought a ticket at an agency counter with cash and has no app can still review from the SMS, and that population is a large part of this market.

---

## 5. The arithmetic

```dart
/// Bayesian shrinkage toward the category mean. A property with one 5-star
/// review must not outrank two hundred reviews averaging 4.6, and a plain
/// mean puts it top — which is the first thing a new listing learns to
/// exploit.
///
///        v            m
///  S = ----- * R  +  ----- * C
///      v + m         v + m
int shrunkX100({
  required int count,        // v
  required int meanX100,     // R
  required int categoryX100, // C — mean over all subjects of this kind in
                             //     this market, recomputed nightly
  int m = 8,                 // reviews at which a subject's own mean carries
                             // half the weight. Tune with real data.
}) => ((count * meanX100) + (m * categoryX100)) ~/ (count + m);
```

Display rules, and each is a decision rather than a default:

- **Below 3 reviews, no score at all.** The listing shows *"Nouveau"* and the review texts. A number derived from two opinions is precision the data does not have, and shrinking it would only disguise that.
- **The primary figure is all-time.** Beside it, *"12 derniers mois"* appears **only when the two differ by more than half a star**. A hotel that got worse should be visible as a hotel that got worse; a hotel that did not should not carry a second number for nothing.
- **Half-star display**, rounded from `shrunk_x100`.
- **Sub-score means are plain means**, not shrunk. They are read as texture beside the headline, not compared across listings, and shrinking them would flatten the one thing they are for.
- Recency is **shown, never baked in**. No decay weighting.

---

## 6. Moderation

Reviews publish immediately. Held-before-publishing is the safe choice and the wrong one: a review that appears three days later reads to its author as suppression, and slow moderation is indistinguishable from censorship.

Three auto-holds, in `bel_reviews` as pure predicates over the text so they are testable without a database:

1. **Contact details** — a phone number in any local format, an email address, a WhatsApp handle, or a URL. Almost always a disintermediation attempt from one side or the other. `held_reason = 'contact_details'`.
2. **A blocklist match**, kept short and covering slurs rather than rudeness. A customer is allowed to be rude about a bad night. `held_reason = 'blocklist'`.
3. **A named private individual** — a capitalised two-word name that is not the property's or operator's own name. *"The manager was unhelpful"* publishes; a named staff member does not. This one has false positives and is therefore a hold for a human, never a removal.

Everything else publishes and is moderated reactively through the report button and the existing platform-staff queue in `apps/admin`.

**What the code must make true, not merely intend:**

- There is **no endpoint, console action or admin action that removes a review without writing a `removed_reason` from a closed set**: `contact_details`, `blocklist`, `named_individual`, `not_about_this_stay`, `duplicate`, `author_request`. There is no `other`, and adding one is a code review that has to justify itself.
- **`operator` is not among the roles that can remove.** Removal is platform staff only, and the console has no such action to hide.
- The author is told which rule, by SMS or email, with the text they wrote, so a removal is never silent.

---

## 7. Contracts

`packages/bel_reviews_contracts`. `ReviewDto`, `ReviewReplyDto`, `RatingSummaryDto`, `SubmitReviewRequest`, `ReviewInvitationDto`, `ReportReviewRequest`.

`RatingSummaryDto` is the one that appears on every search row across three verticals — `count`, `starsX100`, `subMeans`, `count12m`, `stars12mX100`, and a `isNew` flag so a client never has to know the threshold is 3. Nullable everywhere it appears, and a null renders as nothing at all rather than as a zero-star row.

---

## 8. API

- `GET  /reviews/v1/invitations/[token]` — what to ask, including the sub-score keys. Public, no session.
- `POST /reviews/v1/invitations/[token]` — submit. Idempotent: a second submit within the editable window edits; after it, `409`.
- `GET  /reviews/v1/subjects/[kind]/[id]?cursor=` — published reviews, newest first, keyset paginated
- `GET  /reviews/v1/subjects/[kind]/[id]/summary`
- `POST /reviews/v1/reviews/[id]/reports`
- `POST /console/v1/reviews/[id]/reply` — one, under an existing capability
- `GET  /console/v1/reviews?…` — the operator's own, newest first
- `GET  /admin/v1/reviews/moderation` and `POST /admin/v1/reviews/[id]/decision`

Summaries are served from `review.aggregates` and never computed at read time. A results page renders forty listings and must not run forty aggregate queries on a 2G connection's patience.

---

## 9. Surfaces

**Traveller.** A rating on every search row across all three verticals. On a detail page: the headline, sub-scores, and the reviews with replies. A review screen reached from the SMS link, which is the primary path — most reviews will arrive from people who are not in the app.

**Operator console.** Their own reviews newest first, the reply box, and a notification for anything at two stars or fewer with the reply link, sent immediately. Not to give them a head start on removing it — they cannot — but because the fastest useful reply is written while the operator still remembers the booking.

**Admin.** The moderation queue: held reviews with the matched rule highlighted in the text, reported reviews, and the closed-set decision. Plus the category means per subject kind per market, because those are the `C` in §5 and somebody will eventually need to see them to believe the ordering.

---

## 10. Worker

Nightly: recompute `review.aggregates` for subjects with activity, and the category means. Hourly: send due invitations and day-3 reminders. On write: expire eligibilities past their window.

---

## 11. Localization

```
reviews.invitation.title      "Comment s'est passé votre séjour ?"
reviews.invitation.transport  "Comment s'est passé votre voyage ?"
reviews.invitation.rental     "Comment s'est passée votre location ?"
reviews.rating.overall        "Note générale"
reviews.rating.optional       "Facultatif"
reviews.comment.hint          "Ce qui a été bien, ce qui l'a été moins."
reviews.comment.limit         "{count}/1000"
reviews.summary.new           "Nouveau"
reviews.summary.count         "{count} avis"
reviews.summary.last12m       "{stars} sur 12 mois"
reviews.reply.by              "Réponse de {operator}"
reviews.report.action         "Signaler cet avis"
reviews.held.notice           "Votre avis est en cours de vérification."
reviews.removed.contact_details "Votre avis contenait des coordonnées et n'a pas été publié."
reviews.editableUntil         "Modifiable jusqu'au {date} à {time}"

reviews.subscore.ponctualite          "Ponctualité"
reviews.subscore.confort              "Confort"
reviews.subscore.proprete             "Propreté"
reviews.subscore.personnel            "Personnel"
reviews.subscore.emplacement          "Emplacement"
reviews.subscore.rapport_qualite_prix "Rapport qualité-prix"
reviews.subscore.electricite_wifi     "Électricité et wifi"
reviews.subscore.etat_vehicule        "État du véhicule"
reviews.subscore.remise_cles          "Remise des clés"

console.reviews.title         "Avis"
console.reviews.replyOnce     "Une seule réponse par avis."
console.reviews.cannotRemove  "Les avis ne sont pas supprimés à la demande."
```

That last key is a string the operator will read, and it exists so that the answer to the first removal request is already written down and identical to the answer to the hundredth (ADR-0030 §5).

---

## 12. Slices

**V1 — the package and the seam.** `bel_reviews`, `review/0001`, `0002`. *Tests:* `check_layers.dart` fails if `bel_reviews` imports `bel_domain`; two eligibilities for the same `(source_kind, source_ref)` violate the unique constraint.

**V2 — write one.** `review/0003`; submit; the 24-hour editable window. *Tests:* submitting twice inside the window edits and does not duplicate; after it, `409`; a used token cannot be reused; an expired token is refused with a readable reason.

**V3 — the arithmetic.** `shrunkX100`; `review/0004`; the nightly job. *Tests:* one 5.0 against a 4.2 category yields ≈4.3; two hundred at 4.6 yield ≈4.58; the ordering of those two cases is asserted directly, because that ordering is the whole point; below 3 reviews the summary is `isNew`; integer division never produces a value outside 100–500.

**V4 — moderation predicates.** Pure functions, no database. *Tests:* Congolese mobile formats in every spacing variant are caught; `+242 06 123 45 67` and `06.12.34.56.7` and `zero six one two…` in words is **not** caught and that is accepted; a rude review with no contact details publishes; a named individual is held and not removed.

**V5 — display.** The summary on search rows across all three verticals; the detail list. *Tests:* goldens in both themes; a null summary renders nothing rather than zero stars.

**V6 — the reply.** One per review, schema-enforced. *Tests:* a second reply is refused by the constraint, not only by the handler; an operator cannot reach another operator's reviews.

**V7 — reports and the admin queue.** *Tests:* removal without a `removed_reason` from the closed set is impossible; the author is notified with their own text.

**V8 — invitations.** The SMS and email path, the token link, the day-3 reminder, then silence. *Tests:* exactly two messages per eligibility, ever; a used token sends no reminder.

**V9 — transport eligibility.** Written on ticket redemption. *Tests:* a redeemed ticket produces exactly one; a cancelled booking produces none; a refunded booking after redemption keeps the existing one, because the journey happened.

**V10 — rental and stay eligibility.** On return acceptance and the morning after checkout. Per `12-rental.md` R15 and `13-stays.md` S18.

---

## 13. Out of scope for v1

- **Reviews affecting search ranking.** ADR-0030: display-only in v1. Ranking on a young corpus rewards whoever gets the first five happy customers and compounds it forever. When it changes, it changes as a stated change.
- **Photographs in reviews.** A step change in moderation cost.
- **Machine translation of review text.** A bad translation is a claim we made.
- **Replies to replies.** One review, one reply. A thread is a support channel wearing a review's clothes.
- **Reviewer profiles or history.** Anonymity is a feature.
- **Review incentives of any kind** — discounts, credits, prize draws. An incentivised review is a purchased one, and this document exists partly to say that before somebody proposes it as a growth experiment.
