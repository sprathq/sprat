## Opportunity scorecard (discovery workflow only)

For each of the top 3 hypotheses, rate these seven dimensions 1-5 (or `unknown` if you have no
evidence to rate it — never guess a number to fill the gap):

| Dimension | Weight |
|---|---:|
| Severity and recurrence of pain | 20% |
| Evidence of willingness to pay or current spending | 20% |
| Reachability of a specific buyer | 15% |
| Weakness of alternatives and ease of switching | 15% |
| Technical and operational feasibility | 10% |
| Plausible unit economics | 10% |
| Founder advantage | 10% |

For every rating, cite the evidence (source ID or `[assumption]`) that justifies it in one clause.
Do not compute a weighted total yourself — list the seven per-dimension ratings with their
justifications in `artifact_markdown` as a table, one row per hypothesis per dimension (or one table
per hypothesis); the harness computes the weighted score and a sensitivity check afterwards.
