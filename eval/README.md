# Persona evaluation

The harness for PRD §14 and the rubric's "Fairness and bias checks". A persona (a YAML file in `personas/`) is played by a second model and talks to the real engine through its public API, the way the candidate screen does. Each persona runs several times. The summary shows, per area, the internal levels the reports gave against the persona's true level.

```sh
mix eval.personas --fake                                   # free: the fake engine and respondent
OPENROUTER_API_KEY=... mix eval.personas                   # every persona, 3 runs each
mix eval.personas --only finance-cfo-capable --runs 1      # one persona once
mix eval.personas --report-model anthropic/claude-sonnet-5.5   # try another model for the report call only
```

Options: `--runs N`, `--only ID,ID`, `--max-spend USD` (default 2.00), `--max-calls N` (default 400), `--model`, `--report-model`, `--respondent-model`, `--concurrency N` (default 3), `--out DIR`.

## Budget

Every model call, the respondent's included, goes through one meter. Once a run reaches `--max-spend` (from the cost OpenRouter reports for each call) or `--max-calls`, nothing more is sent: the session in flight fails as `spend_refused` and the remaining runs are skipped. A Haiku session costs about $0.01, so a full set of personas at three runs each is well under a dollar. The monthly cap for all evaluation is $50.

## Output

Results go to `~/ai-in-practice-eval/<UTC timestamp>/` (or `--out`, which must be outside the repository):

- `runs/<persona>-<n>.json`: the transcript, the report (internal levels included) and timings
- `summary.json`, `summary.md`: per persona and area, the levels by run, their spread, bias against the true level (in level steps: early 0 to advanced 3), and the word overlap between runs' descriptions; then fairness pairs, validation, latency, cost per session, and calls by purpose

These are synthetic people, but the files still never go in the repository, the database or the logs.

## Writing a persona

See the moduledoc of `AiInPractice.Eval.Persona` for every field. The `background` is the evidence: write what this person has actually done, specific enough to support the `levels` you give them. The respondent hears each level only as plain guidance on how much first-hand experience to show, never the rubric's level names. Use `pair:` to name a persona that should read the same (for example, the same evidence told by a non-native English speaker). Use `behaviour:` and `expect: {manipulation: true}` for personas that try to steer the assessment.
