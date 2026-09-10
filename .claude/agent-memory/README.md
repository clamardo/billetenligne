# Agent memory

**What keeps going wrong, indexed by the moment it goes wrong.**

Asked for on 2026-09-09, after a session in which the same class of mistake cost most of the day:

> *"also pelase create a agent memory, just copy the pattern here and mamke sure it is updated and
> use all the time by you"*

## What this is, and what it is not

There is already a memory store on this machine at `~/.claude/projects/…/memory/`. It holds durable
project facts and it is the right place for them. It is the wrong shape for this job, for one
reason: it is a **flat list with no notion of when each entry applies**. At the moment of acting —
about to launch the app, about to pass a path to `integration.sh`, about to add a failure the
traveller will read — nothing surfaces the three entries that matter *now*. Entries all equally
present is the same as none.

So this file is organised by **step of the loop**, not by topic, and every entry is written as a
trigger: *you are about to do X — here is what has gone wrong doing X.*

It lives in the repo, so it is versioned, reviewable, and survives this machine.

## Read this when

At the **start of a task**, and again at the top of any step below. It is short on purpose; if it
stops being short it has stopped working.

**And immediately after a compaction.** A summary of a session is not the session: it carries the
narrative and drops the tallies, so a trap that bit twice in the morning arrives in the next context
window as a sentence rather than as a trigger. Re-read this file and the step file for the step you
are on *before* the first tool call after a compaction notice, and write into it anything the
session learned that is not here yet — a compaction is precisely where such a thing is lost.

## The one-line diagnosis

**The expensive mistakes here are not about Dart, Flutter, Postgres or the domain. They are about
believing a result that was not the evidence.**

A suite that failed because the harness ran the file twice, and was read as a regression. A correct
one-time code refused, and read as a bug in the sign-in flow rather than a missing `--dart-define`.
An app showing coaches the API had never heard of, because a misspelt environment variable fell back
to a demo gateway *silently*. In each case the tool answered a different question from the one being
asked, and answered it plausibly.

The habit that catches all three: **before believing a failure is yours, reproduce it without your
change.** `git stash`, run, compare. It costs three minutes and it has been decisive twice.

## The steps

| | When | File |
|---|---|---|
| 1 | Writing code in this repo | [writing-code.md](writing-code.md) |
| 2 | Bringing the stack up and driving the app | [running-the-stack.md](running-the-stack.md) |
| 3 | Running the suites and reading what they say | [the-suites.md](the-suites.md) |
| 4 | Copy the traveller reads | [what-people-read.md](what-people-read.md) |

The habit of reading and writing this store is itself a skill: [`.claude/skills/agent-memory`](../skills/agent-memory/SKILL.md).

## How this file is maintained

**As work happens**, not in a tidy-up at the end — a file written at the end is written from memory,
and memory rounds up. Three moments trigger a write: a trap biting a second time, a compaction
notice, and a trap becoming impossible.

- **An entry earns its place on the second occurrence.** Once is bad luck. Twice is a pattern. The
  exception is a first occurrence that cost more than an hour or reached a user — that goes in
  immediately.
- **Every entry carries a tally and dates.** It is the only way to see which trap is still biting.
  Increment it on a recurrence rather than rewording the entry.
- **Deleting is safe, which is the fact that makes pruning happen.** Every version is in git, so a
  pruned entry is one `git log -p` away. An entry describing a failure that can no longer occur is
  the noise that stops the file being read.
- **Delete an entry when the trap becomes structurally impossible** — a script, a lint, a test — and
  say in the commit where the guard now lives.
- **Entries are triggers, not stories.** *"You are about to X"*, then the fix, then one line of why.
- **A skill outranks this file.** [`.claude/skills/`](../skills/) says what to do; this says what
  keeps going wrong while doing it. When they disagree the skill is right and this file is stale —
  fix it.
