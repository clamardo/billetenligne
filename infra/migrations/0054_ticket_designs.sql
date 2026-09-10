-- 0054_ticket_designs — the operator's own stationery, as rows.
--
-- Most seats in this market are bought with cash at a counter by somebody who
-- will not install an app, and that sale ends with a printed ticket. The
-- ticket already renders (`PrintedTicketPage`), from `TicketDesign` — but
-- until now the design was a compiled-in starter, identical for every
-- company. This is where an operator's own choice lives.
--
-- **The design is a JSONB document, not a column per setting.** Two reasons,
-- and the first is not "flexibility":
--
--   * the vocabulary is already closed and validated in Dart
--     (`TicketDesign`, eight hues, four motifs, a fixed set of optional
--     lines), so a CHECK constraint per setting would be the same rule
--     written twice and eventually disagreeing with itself;
--   * a build that meets a design saved by a newer build has to print a
--     ticket anyway. `TicketDesign.fromJson` is deliberately tolerant, and a
--     column that refuses the row would turn "somebody enabled a field you
--     have not deployed yet" into "the counter cannot sell".
--
-- What *is* constrained here is the one thing a wrong value would make
-- unreachable rather than merely ugly: the format, because it decides the
-- sheet the browser is told to print on.

BEGIN;

CREATE TABLE IF NOT EXISTS ticket_designs (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID NOT NULL REFERENCES operators(id) ON DELETE CASCADE,

  -- What the operator called it. Theirs, not ours: "guichet Mikalou",
  -- "grand format pour les anciens".
  name        TEXT NOT NULL,

  format      TEXT NOT NULL,
  CONSTRAINT ticket_designs_format_known
    CHECK (format IN ('boardingPass', 'a4')),

  -- `TicketDesign.toJson()`. See the header.
  design      JSONB NOT NULL,

  -- The one printed when nobody chose. At most one per format per operator,
  -- so "print" at a till is never a question.
  is_default  BOOLEAN NOT NULL DEFAULT false,

  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ticket_designs_one_default_per_format
  ON ticket_designs (operator_id, format) WHERE is_default;

CREATE UNIQUE INDEX IF NOT EXISTS ticket_designs_operator_id_lower_name_idx
  ON ticket_designs (operator_id, lower(name));

ALTER TABLE ticket_designs ENABLE ROW LEVEL SECURITY;
-- FORCE so the policy applies to the table owner too (0004's rule for every
-- tenant-scoped table): without it a migration run or an admin session sees
-- every operator's stationery.
ALTER TABLE ticket_designs FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ticket_designs_tenant_isolation ON ticket_designs;
CREATE POLICY ticket_designs_tenant_isolation ON ticket_designs
  USING (operator_id = app_tenant_id() OR app_is_platform())
  WITH CHECK (operator_id = app_tenant_id() OR app_is_platform());

GRANT SELECT, INSERT, UPDATE, DELETE ON ticket_designs TO bel_app, bel_admin;

-- A print is a third way a link is minted, beside email and SMS.
--
-- The vendor at the till has no URL to open, and that is deliberate: the
-- send path never returns one, because a URL on a counter screen is a ticket
-- anybody standing behind the customer can photograph. A print link is the
-- narrow exception — minted for one press of one button, valid for minutes
-- rather than a month, and never sent anywhere. `sent_to` records the till it
-- was printed at rather than an address, which is what an operator asking
-- "who printed this twice" needs.
ALTER TABLE ticket_links DROP CONSTRAINT IF EXISTS ticket_links_channel_known;
ALTER TABLE ticket_links ADD CONSTRAINT ticket_links_channel_known
  CHECK (channel IN ('email', 'phone', 'print'));

COMMIT;
