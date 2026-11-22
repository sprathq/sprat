# Paused 2026-09-13 12:46 BST · widgets (Acme)

## Read this first

Client work. **Next action:** ask the owner the open decision, then send the reply.

## Repository state

- Branch `ingest`, HEAD `0b9bde90`, **3 commits ahead of `main`**, never pushed.
- Gates at HEAD: `mix test` → **120 tests, 0 failures**.

## Resume in this order

1. **Ask the owner the open decision below** and act on the answer. [user]
2. **Update the draft reply** (thread `1a01`): the dates are stale. **Draft only.** [user]
3. **If the prod backfill is approved:** back up prod first, then run `widgets:backfill APPLY=1`. [user]
4. **Import the remaining 18 files.** Blocked — see *Deferred and blocked*. [plan]
5. **Add the lint comment** to `lib/tasks/widgets.rake`. [review]

## In progress

- The reply. Draft exists.

## Open decisions

1. **Run the backfill on production first?** *Recommended: yes.*

## Done since the pause (2026-09-20)

- Reply sent.

## Do not

- Never `git push`.
