## Output format

Your response is constrained to this JSON shape (you do not need to add the JSON fences yourself,
the harness enforces the schema):

- `artifact_markdown` (string): your full artifact for this stage, in Markdown, following the section
  headings given in the stage instructions below.
- `sources` (array): every source you cited this stage. Each item has `id` (a short stable ID such as
  `S1`, `S2`, unique within this stage), `url`, `title`, `publisher` (string or null), `published`
  (a date string or null if unknown) and `supports` (an array of the specific claims, quoted or
  closely paraphrased, that this source backs up).
- `assumptions` (array of strings): every `[assumption]` you made, restated plainly, one per entry.
- `handoff` (string): a short note (3-8 sentences) to whoever reads this artifact next, naming what
  you're confident in, what's still open, and anything they should double-check.

Only include a source in `sources` if you actually found and read it. Do not pad the list.
