---
version: 1
slug: "lib-sprat-terminal"
primary_target: "lib/sprat/terminal"
related_targets: ["docs/spec-v4.md"]
---

# Surface: Sprat Observer TUI (board, project, session)

Mode: Operate. Always-on terminal pane beside the Claude Code sessions it watches; narrow-and-tall as often as wide. Spec: docs/spec-v4.md §10.

Audience/job: the owner triages many projects at a glance, sends or dismisses drafted nudges, answers what only they can answer, and drills into one project when needed.

Constraints: terminal only (owner's monospace font, 16/256/truecolor); NO_COLOR and ASCII mode carry every state; mouse optional; the fish mascot `><>` is binding; no multi-pane zone layout; no light/white filled surfaces (owner rejected the white ticket stock).

## Direction contract

THESIS: The owner is the expediter at the pass. Work that needs them hangs on the rail as tickets aging left to right; the rest of the kitchen (every project) runs below as the line. It refuses the category default of a sortable table with a detail split and an F-key bar.

OWN-WORLD: Dark kitchen-steel ground everywhere, no light fills. Tickets are outlined in a dim warm rule on that same ground, their text in warm paper tone; the selected ticket's outline brightens. The only filled shape is each ticket's age stamp, a small chip that steps dim -> amber -> red as it ages. Amber means "you", red means "stuck", dim warm grey is everything quiet. The line and the log are unboxed text ranked by brightness.

STORY: Sprat is the expediter, the owner the chef. Glance at the rail: yours tickets first (what only the owner can do, with what Sprat already did meanwhile), then sprat tickets (PM runs in progress, quiet). Fire a suggested answer (f), open to see the PM run (enter), dismiss or mark done (x). Glance at the line: every project's position and whether it is moving. Below: what was served today.

FIRST VIEWPORT: Header row (SPRAT, the fish facing you when the rail is non-empty, time). THE RAIL: up to three outlined tickets side by side at >= 90 cols (one-line strips stacked below that), oldest left, each with age chip, project, the one-line obstacle, the ready action. THE LINE: one row per project: phase, done/total, fixed-scale bar, current item, session glyphs. SERVED TODAY: progress and resolved nudges. Footer: keys. Primary action: `f` fire on the selected ticket.

FORM: The Pass (kitchen ticket rail and expediter), position 1 on my ordered list, chosen by the owner as IMPECCABLE'S PICK over the assigned Departures; owner steer: no white ticket stock. seed:e6643768d95ed606. Signature move: ticket aging, the age chip stepping colour at the rule's thresholds; the only motion is a ticket sliding onto or off the rail.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Open
- Ticket width and rail behaviour under 60 cols.
- Whether kitchen verbs (fire, 86) stay as key labels or become plain (send, dismiss) with the kitchen words only in help.
