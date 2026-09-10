---
name: agent-memory
description: Use when starting or resuming a task in this repo, immediately after a compaction notice, and whenever something has just gone wrong, been fixed, or bitten twice — the moments when `.claude/agent-memory/` should be read before acting or written before the lesson is lost.
---

# The agent memory is the part of you that survives compaction

Everything else in a session is temporary. The conversation gets summarised; the summary keeps the
narrative and drops the specifics — the exact flag, the exit code that lies, the tally that said a
trap was on its third occurrence. `.claude/agent-memory/` is the only place a fact written today is
still there, in its useful form, ten sessions from now.

That is what it is for. Not documentation, not a changelog: **a working note from you to the next
you, who will arrive with none of this context and will otherwise make the same mistake again.**

## Where it lives

| | Step of the loop | File |
|---|---|---|
| — | Why the file is shaped this way, how it is maintained | `.claude/agent-memory/README.md` |
| 1 | Writing code in this repo | `.claude/agent-memory/writing-code.md` |
| 2 | Bringing the stack up and driving the apps | `.claude/agent-memory/running-the-stack.md` |
| 3 | Running the suites and reading what they say | `.claude/agent-memory/the-suites.md` |
| 4 | Copy the traveller reads | `.claude/agent-memory/what-people-read.md` |

Indexed **by the moment it bites**, not by topic. A trap you cannot surface at the moment of acting
is a trap you will hit.

There is a second store at `~/.claude/projects/…/memory/`. That one holds durable *facts* — who the
user is, what they have asked for, standing preferences. This one holds *traps*. When in doubt: a
fact about the person or the project goes there; a thing that will go wrong while doing the work
goes here, in the repo, where it is versioned and reviewable.

## Reading

**Read `README.md` plus the step file for the step you are on:**

- at the **start of a task**;
- at the **top of each step** — the moment you move from writing code to running the stack is the
  moment to open `running-the-stack.md`;
- **immediately after a compaction notice, before the first tool call.** This is the one that is
  always skipped and always the most valuable. The summary you just read is not the session.

```bash
cat .claude/agent-memory/README.md .claude/agent-memory/running-the-stack.md
```

Reading it is cheap — the whole store is a few hundred lines by design. If it has grown past
skimmable, that is a signal to prune, not to skip.

## Writing

**Write as work happens, not in a tidy-up at the end.** A file written at the end is written from
memory, and memory rounds up: it keeps "the tests were flaky" and loses `--fatal-warnings`.

### What earns an entry

- **A trap on its second occurrence.** Once is bad luck; twice is a pattern. Increment the tally on
  a recurrence rather than rewording the entry.
- **A first occurrence that cost more than an hour, or reached a user.** Straight in.
- **Anything discovered at a compaction boundary** — that is precisely where such things are lost.
- **A tool that answered a different question from the one you asked, plausibly.** This repo's
  expensive mistakes are almost all of this shape: a suite that failed because the harness ran the
  file twice; a correct code refused because of a missing `--dart-define`; a `pkill` that exits 144
  whether or not it worked. Believing a result that was not the evidence.

### What does not

- Anything the repo already records — code structure, ADRs, git history, `CLAUDE.md`.
- Anything that only matters inside this conversation.
- Anything a script, lint, or test now makes impossible. That is a **deletion**, not an entry.

### The shape

Entries are **triggers, not stories**: *you are about to do X — here is what has gone wrong doing
X*, then the fix, then one line of why.

```markdown
---

## `pkill` chained to the relaunch exits 144 and the relaunch never happens

**Tally: 3 — all 2026-09-09.**

```bash
pkill -f "flutter_tools.*run" && flutter run …     # exit 144, no relaunch
```

**144 is what this `pkill` returns here even when it worked.** So it is useless as a success signal
and fatal as a `&&` guard.

**Do instead:** issue the kill as its own call, ignore its exit code, and launch separately.
```

A heading somebody would recognise mid-mistake. A **Tally** with dates. The wrong way, then the
right way, with real commands. No narrative.

### After writing

Nothing to sync — these are plain files in the repo. Commit them with the work they came from, so
the entry and the fix are one change and `git log -p` explains both.

## Pruning

**Deleting is safe, and that is the fact that makes pruning happen** — every version is in git, so
a pruned entry is one `git log -p` away.

Delete an entry when the failure becomes **structurally impossible**: a script that takes the flag
for you, a lint that catches the pattern, a test that guards the behaviour. Say in the commit
message where the guard now lives. An entry describing a failure that can no longer occur is the
noise that stops the file being read at all.

## When the memory and a skill disagree

**The skill is right and the memory is stale.** `.claude/skills/` says what to do; the memory says
what keeps going wrong while doing it. If the memory contradicts a skill, fix the memory in the
same change.

## Red flags

| Thought | Reality |
|---|---|
| "I'll write this up at the end of the task" | The end of the task is after a compaction. Write it now. |
| "I'll remember this one" | You will not. That is the entire premise of the file. |
| "It only happened once" | Did it cost an hour, or reach a user? Then it goes in now. |
| "The summary covers it" | A summary keeps the narrative and drops the flag that mattered. |
| "The file is getting long" | Prune it. Do not stop writing to it, and do not stop reading it. |
| "This is obvious from the code" | Then it belongs in the code, not here — and check that it is. |
