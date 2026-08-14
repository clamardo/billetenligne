# ADR-0030 — Reviews: earned, verified by construction, and not for sale

**Status:** Accepted · **Date:** 2026-08-14 · **Depends on:** ADR-0027 · **Reads with:** ADR-0029, `14-reviews.md`

## Context

Every vertical in this product asks a stranger to pay before they receive anything. A coach seat, an aircraft seat, a car worth twenty-five million francs, a room in a town they have never visited. `09-roadmap.md` lists *"travellers do not trust prepayment"* as a live, unmitigated risk with the note **"Design done; unproven"**.

Reviews are the mechanism the whole internet settled on for that problem, and they are worth more to this product than to most, for a specific reason: **we have information nobody else has.** We know the booking happened, we know it was paid for, we know the ticket was scanned at the door or the guest checked in. An open review platform guesses at all three.

They also matter unevenly. A coach company's reviews are useful; a hotel's are close to decisive. `ADR-0029` puts stays into a category where the incumbent's entire moat is a decade of accumulated review text.

And reviews are where a marketplace's integrity is either established or quietly sold. That is why this is an ADR and not a feature ticket.

## Analysis

### The rule that makes it worth anything

**Only a completed booking can leave a review, one review per booking.**

That is the whole design. Everything else follows from it:

- No account farming. A review costs the price of a real booking, taken on a real payment rail.
- No competitor bombing. A competitor can write ten reviews for the price of ten stays, which is a business decision rather than an afternoon.
- No review of a service somebody did not receive. A cancelled booking, a released hold and an unpaid reservation are all ineligible.
- **No "verified" badge**, and the absence is the point: on this platform there is no other kind. A badge implies unbadged reviews exist somewhere on the page, and they do not.

The identity anchor is the booking, not the user. One person who stays somewhere three times leaves three reviews, which is correct — they had three experiences.

### 1–5, not 1–10

Booking.com uses 1–10 with sub-scores; Airbnb and Google use 1–5. We use **1–5 stars, displayed to the half-star**.

The reason is regional, not aesthetic: the rating scale people here already read is Google Maps'. A 1–10 scale has to be taught, and a channel whose ratings need explaining loses to one whose do not. It also has a known pathology — on a 1–10 scale, sub-8 becomes "bad" and the usable range collapses to three values.

Official star **classification** — the Ministry of Tourism kind — is a completely different thing, is nullable, is most often absent, and is never computed, blended or displayed as though it were a guest rating (`ADR-0029`).

### The arithmetic, because a naive average is a lie

A property with one 5-star review must not outrank a property with two hundred reviews averaging 4.6. Shown as a plain mean, it does, and the first thing a new listing learns is to ask one friend.

The displayed score is a **shrunk mean**, pulled toward the category average in proportion to how little evidence there is:

```
      v           m
S = ----- · R + ----- · C
    v + m       v + m

  v = this subject's review count
  R = this subject's mean rating
  C = the mean rating across all subjects of this kind in this market
  m = the shrinkage constant — the number of reviews at which a subject's
      own mean carries half the weight. Start at 8 and tune with real data.
```

With `m = 8`, one 5.0 review displays as roughly 4.3 against a category mean of 4.2, and two hundred reviews at 4.6 display as 4.58. That is the correct ordering and it needs no special case.

Two further rules:

- **Below 3 reviews, no score is displayed at all.** The listing shows *"Nouveau"* and the review texts. A number derived from two opinions is precision the data does not have, and shrinking it toward the mean would only disguise that.
- **Recency is shown, not baked in.** The primary figure is all-time; beside it sits *"12 derniers mois"* when the two differ by more than half a star. A hotel that got worse should be visible as a hotel that got worse, and silently weighting recent reviews hides both the fact and the trend.

### Moderation: fast by default, held for one specific thing

Held-for-review-before-publishing is the safe choice and it is the wrong one: a review that appears three days later is a review the author assumes was suppressed, and slow moderation is indistinguishable from censorship.

**Reviews publish immediately.** Three exceptions are auto-held for a human:

1. **Contact details.** A review containing a phone number, an email address or a WhatsApp handle is almost always a disintermediation attempt — *"call me direct, cheaper"* — from either side. Held, and the pattern is worth watching in its own right.
2. **A blocklist match**, kept short and covering slurs rather than rudeness. A customer is allowed to be rude about a bad night.
3. **Anything naming a private individual by full name.** "The manager was unhelpful" publishes; a named staff member does not.

Everything else publishes and is moderated reactively, through a report button and the platform-staff queue that already exists in `apps/admin`.

### The operator's rights, and their limits

An operator may reply. **Once**, publicly, attributed, with no editing of the review and no removal of it, ever.

The right of reply is genuinely valuable — a calm answer to an angry review persuades more readers than the review does — and it is also the pressure valve that stops an operator's only recourse from being to complain to us.

Three things an operator may never do, written here so that the first time somebody asks, the answer is already a decision and not a negotiation:

- **Pay to have a review removed.** Not as a fee, not as a "premium listing" benefit, not as a goodwill gesture at any commission rate.
- **Have a review removed for being negative.** Only for violating the moderation rules, and the author is told which.
- **See who wrote it beyond what every reader sees.** The operator has the booking, so they can usually work it out; the platform does not hand it to them, because an operator who can trivially identify a reviewer is an operator whose reviewers self-censor.

Reviewers are displayed as a first name and an initial — *"Aline M."*. Never a full name, never a phone number, never a link to a profile.

### Ranking, and the honest v1 answer

Reviews **do not affect search ranking in v1.** Ordering stays by departure time, price or distance, and the rating is displayed on the row.

Ranking on reviews with a young corpus rewards whoever gets the first five happy customers and compounds it forever. Once the corpus is real, ranking on the shrunk mean is the obvious next step — and it needs to be introduced as a stated change, not slipped in, because the moment ranking depends on reviews the incentive to manipulate them changes completely.

### Where the code lives, given ADR-0027

Reviews are the one genuinely cross-vertical concern, which makes them the exact thing ADR-0027 §9 warns about: the pressure to reach into every vertical from one shared place.

They do not reach in. `bel_reviews` depends on `bel_platform` and on nothing else, and it **never reads a vertical's tables**. The verticals push, using the same narrow-seam pattern as `public.payables`:

when a service completes — a ticket is scanned, a car is returned, a guest's checkout date passes — the vertical writes one `review.eligibilities` row: a token, a subject kind and id, the purchaser, the completion instant, an expiry, and **the list of sub-score keys to ask about**. That last field is what keeps the reviews package free of vertical knowledge: it never switches on `bus` or `stay`; it renders the sub-scores it was handed and stores them by key.

## Decision

**One review per completed booking, 1–5 stars with per-vertical sub-scores supplied as data, published immediately except for three named holds, one public operator reply, a shrunk mean displayed only above three reviews, no ranking effect in v1, and no removal for money under any circumstances.**

### 1. Subjects

`subject_kind` is `operator` or `property`.

A coach company, an airline and a rental company are reviewed as **operators**. A hotel is reviewed as a **property**, because a chain's two hotels are two different experiences and a guest rating them as one entity would be rating the wrong thing.

Nothing smaller is reviewable. Reviews of an individual coach, a specific room type or one car are noise: the sample per subject collapses, and nobody chooses a hotel by room-type rating.

### 2. Sub-scores

Supplied by the vertical, stored by key, translated from the catalog, never enumerated in `bel_reviews`.

- **Transport** — `ponctualite`, `confort`, `proprete`, `personnel`
- **Rental** — `etat_vehicule`, `proprete`, `remise_cles`, `rapport_qualite_prix`
- **Stay** — `proprete`, `emplacement`, `personnel`, `rapport_qualite_prix`, `electricite_wifi`

That last key is the market-specific one and it exists for the same reason `groupe_electrogene` does in ADR-0029: whether the power and the wifi actually worked is the question a traveller here most wants answered, and no incumbent asks it.

Sub-scores are optional for the reviewer. The overall star rating is not.

### 3. Lifecycle

Eligible at completion · window closes 30 days later · one review, editable by its author for 24 hours then frozen · author deletion hides it and keeps the row, because a review is evidence in a dispute and a deleted-by-request row that vanishes takes the operator's reply with it.

An operator is notified of any review of two stars or fewer, immediately, with the reply link. Not to give them a head start on removing it — they cannot — but because the fastest useful reply is the one written while the operator still remembers the booking.

### 4. Schema

Schema `review`, its own migration sequence, referencing `public.operators` and `public.user_accounts` and nothing else. Tables: `eligibilities`, `reviews`, `replies`, `reports`, `aggregates`.

`aggregates` is a materialised per-subject rollup — count, mean, shrunk mean, per-sub-score means, 12-month equivalents — recomputed by `services/worker` rather than at read time. A search results page renders forty listings and must not run forty aggregate queries on a 2G connection's patience.

### 5. The commitments, stated as commitments

Because these are the ones that get eroded quietly, and a decision written down is harder to erode than a habit:

- Reviews are never removed for money.
- Reviews are never removed for being negative.
- The displayed score is never a plain mean.
- No review is ever written by us, by a bot, or by anyone who did not complete a booking.
- The moderation rules are published where reviewers can read them.

## Consequences

**Good.** The strongest available answer to the roadmap's *"travellers do not trust prepayment"* risk. A structural integrity advantage over any open review platform, at zero cost, because we already hold the booking. Reviews are the enforcement mechanism behind ADR-0028 §5's decision to leave security deposits with the operator — an operator who mishandles deposits acquires a public record of doing so. One package serving four verticals without knowing what any of them sell.

**Bad.** A moderation queue is ongoing human work that does not scale with automation and must be staffed from the first review. The reply flow, the report flow, the notification and the admin queue are all real surface. Aggregates are a cache, and every cache is a staleness bug waiting.

**Risk — the empty corpus.** A review system with no reviews is worse than none: it advertises that nobody has been here. Mitigations: no score below three reviews, review requests sent at the right moment (a coach arrival, a hotel checkout) rather than immediately at booking, and the reviews surface hidden entirely on a vertical until its corpus is real.

**Risk — the first operator who demands a removal.** It will happen in the first month, it will come from an operator we need, and the answer has to be the same as it will be in year three. That is why §5 is written as commitments and why this is an ADR: so that the decision was made calmly, in advance, by somebody who was not on the phone at the time.
