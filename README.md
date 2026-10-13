# AI in Practice

A framework from [DSC](https://dsc.net) for a conversation about how a senior person works with AI, published at `ai-in-practice.dsc.net`.

A 20 to 25 minute AI-led conversation produces two written reports: a private, developmental one for the person, and a signed one they can choose to release to a recruiter, CEO or board member. **It is a conversation starter.** It gives no score, ranks no one and makes no decision about anyone. It is not a product: there is no sign-up, no pricing and no public access. Links are issued personally.

This repository holds the whole application and the rubric it assesses against, so anyone can check what it does and does not do with what people say.

## The rubric

[`priv/rubric/rubric.md`](priv/rubric/rubric.md) sets out the principles, the five areas (understanding, personal use, applying AI to the business, leading adoption, attitude), how expectations change by role, and what each report contains. Its `version` front matter is shown in every page footer and report.

## Privacy design, and how the code shows it

| Claim | Where to check |
|---|---|
| The conversation is held only in server memory for the session, then discarded. It is never written to disk, the database or logs. | `lib/ai_in_practice/assessment/session.ex`: one process per conversation, which stops (and drops everything) when the page closes, at the 40-minute hard stop, or an hour after the report is ready. Tests: `test/ai_in_practice/assessment/session_test.exs`, `session_privacy_test.exs`. CI's **privacy gate** runs every test tagged `:privacy`. |
| Crash reports and debugging dumps show no words from a conversation. | `format_status/1` in the session; `lib/ai_in_practice/log_redaction.ex` strips call arguments, process state and message text from every crash report; transcripts and reports `inspect` as redacted. Tests: `test/ai_in_practice/log_redaction_test.exs` |
| Model requests ask for zero data retention, and logs carry the status and latency of a model call, never what was sent or received. | `lib/ai_in_practice/llm/open_router.ex`. Test: `test/ai_in_practice/llm/open_router_test.exs` |
| Answers are treated as data, never as instructions; an attempt to steer the assessment is ignored and noted in the assessor report. | `lib/ai_in_practice/assessment/conversation_prompt.ex`, `report_prompt.ex`, `report.ex` |
| The database holds link and usage data only: token hashes, link type, the recruiter firm and contact (entered by DSC), quota, role group, status and timestamps, plus the curated reading list. Nothing that identifies a candidate. | `priv/repo/migrations`, `lib/ai_in_practice/links.ex`. Test: `test/ai_in_practice/links/schema_test.exs` checks no column could hold session data |
| Link tokens are 256 random bits, and only their SHA-256 hash is stored, so the database alone cannot open a link. A new link's address is shown once. | `lib/ai_in_practice/links/token.ex` |
| A recruiter's labels for their candidate links (e.g. initials) stay in their own browser and are never sent to the server. | `lib/ai_in_practice_web/live/recruiter_live.ex`. Test: `test/ai_in_practice_web/live/recruiter_live_test.exs` |
| Link tokens never reach the logs, nor do answers or the session id that report downloads use. | `lib/ai_in_practice_web/plugs/request_logger.ex` redacts them from request paths. `config/config.exs` filters `token`, `answer` and `session` from logged params. Tests: `test/ai_in_practice_web/plugs/request_logger_test.exs`, `test/ai_in_practice_web/live/assessment_privacy_test.exs` |
| Reports are downloaded from the live session's memory, and from nowhere else. Once the page is closed or the hour is up, there is nothing to download. | `lib/ai_in_practice_web/controllers/report_controller.ex`. Test: `test/ai_in_practice_web/controllers/report_controller_test.exs` |
| An unusable link says nothing about itself: unknown, withdrawn, used and completed links get the same page. | `lib/ai_in_practice_web/plugs/usable_link.ex`. Test: `test/ai_in_practice_web/plugs/usable_link_test.exs` |
| Assessment pages and report downloads are never cached or indexed, and links do not leak through the `Referer` header. | `lib/ai_in_practice_web/plugs/security_headers.ex` |
| No third-party requests: fonts are self-hosted and there is no analytics. | `priv/static/fonts`, `test/ai_in_practice_web/design_system_test.exs` |
| Admin is reachable only over Tailscale, on a separate listener with its own router. | `lib/ai_in_practice_web/admin/`, `lib/ai_in_practice/admin_bind.ex`, `test/ai_in_practice_web/admin_endpoint_test.exs` |

Third parties in the data path: Cloudflare (which fronts the site and terminates TLS), and OpenRouter and the underlying model provider (zero data retention).

## The assessment engine

`lib/ai_in_practice/assessment/` runs the conversation and writes the reports (PRD §8):

- **Prompts are built from the rubric file** (`lib/ai_in_practice/rubric.ex`), with each role group's calibration and no other group's. Snapshots of every prompt are in `test/snapshots/prompts`, so a prompt change shows up as a diff. After a deliberate change, run `UPDATE_SNAPSHOTS=1 mix test` and review the diff.
- **Each turn** the model writes the next question from what has been said and reports which of the five areas it now judges covered. The engine steers towards the gaps and closes when every area is covered (after at least 8 main questions), or at a limit: 14 main questions, 24 turns, a token budget, or the 40-minute hard stop. The person can finish early.
- **The report** is a separate call returning JSON for both reports. Code then checks it: a quote that is not word for word in the person's answers is dropped; a reading pick not on the curated list is dropped; a level name or a score in the text, or a missing section, means one regeneration and then an apology.

Try it in a terminal (nothing is saved):

```sh
mix assessment.try finance --fake                       # the fake model, no cost
OPENROUTER_API_KEY=... mix assessment.try board_ned     # the real model
```

Set `FAKE_LLM=1` to run the dev server on the fake model (development only). To see the error screens, set `FAKE_LLM` to one of these values instead:

- `spend_refused`: refused before the first question (the "not available just now" screen; the link stays unused)
- `fail_mid`: fails after two questions
- `report_invalid`: the reports cannot be written
- `short`: a normal run with a one-minute hard stop

## The candidate journey

`/a/TOKEN` is one LiveView, `lib/ai_in_practice_web/live/assessment_live.ex` (PRD §7):

1. **Start screen.** What this is and what it is not, the time it takes, one attempt, anonymising, how answers are handled, and (for a recruiter's link) who sent it and what they can see. The role group is shown, or chosen for an individual link. Opening it does not use the link.
2. **Conversation.** One question at a time, with focus moved to each new question. Paste and drop are refused in the answer box (dictation still works). A quiet five-segment progress rule. "Finish early", with a confirmation. The browser warns before the page is closed.
3. **Generating**, then **reports**: both reports on screen (the candidate's, then the assessor's), with a download for each and a prominent warning that nothing is kept.

The link is used up when the first question arrives and completed when the reports arrive. **Error screens:** temporarily unavailable (before the first question, with the link unused), a failure mid-conversation, reports that could not be written, no answers, and reports past their hour. The screens after the link was used say who can send a new one: the recruiter, or David for an individual link.

**Reconnecting:** if the connection drops, the page reattaches to the same session for up to two minutes. Reloading or closing the page ends the conversation.

The PDFs are interim plain renderings (`lib/ai_in_practice/reports/pdf.ex`) of the same content the screen shows (`lib/ai_in_practice/reports/content.ex`). Epic 5 replaces them with the designed A4 templates and signs the assessor report.

## Links and access

There are no accounts. A link's token is the only credential (PRD §6).

- **Recruiter-mode link** (`/r/TOKEN`): DSC issues it to a firm. The recruiter mints up to their quota (default 10) of single-use candidate links, choosing a role group for each, and sees whether each is unused, started or completed.
- **Individual-mode link** (`/a/TOKEN`): one assessment link, with a label DSC chooses. The person picks their role group.
- A link is **used up when the first question appears**. A start that fails before then leaves it unused. A link that was started and never completed cannot be reopened, but it stops counting against the recruiter's quota.
- The admin usage table shows a started link as **abandoned** once it is more than an hour old and still not completed (past the 40-minute hard stop).

### Admin

The admin pages are at `/admin` (links, quotas, revoking, usage) and `/admin/reading` (the reading list), on the Tailscale-only listener. The same link operations are available from the command line:

```sh
# development
mix links recruiter --firm "Northgate Search" --contact "Sam Jones" --email sam@example.com [--quota 10]
mix links individual --label IND-014
mix links quota RECRUITER_ID 15
mix links revoke recruiter RECRUITER_ID
mix links revoke link LINK_ID
mix links usage

# on a release (runs inside the running node)
bin/links usage
```

## Versions in the footer

Every page footer shows the code version (the git SHA the release was built from), the rubric version and the model, in lower case mono. For example: `code 1a2b3c4d5e6f · rubric v0.2 · model anthropic/claude-haiku-5.5`. Compare the code version with this repository's history to see exactly what is running. Builds without a SHA show `code dev`. See `lib/ai_in_practice/version.ex`. The release image bakes the SHA in with `docker build --build-arg GIT_SHA=$(git rev-parse HEAD) .`

## Running it locally

You need Elixir 1.20 and Erlang/OTP 27 (see `.tool-versions`).

```sh
mix setup
mix phx.server
```

- Public site: <http://localhost:4100>
- Admin: <http://localhost:4101/admin> (localhost only in dev. Set `ADMIN_IP` to bind it elsewhere)

Production needs `DATABASE_PATH`, `SECRET_KEY_BASE`, `PHX_HOST` and `ADMIN_IP` (the host's Tailscale address). `OPENROUTER_API_KEY` is needed for the model. Optional: `ADMIN_PORT` (default 4001), `PORT` (default 4000), `OPENROUTER_MODEL`. The app refuses to start if `ADMIN_IP` is missing or is `0.0.0.0` or `::`.

## CI gates

Every push and pull request to `main` runs [`.github/workflows/ci.yml`](.github/workflows/ci.yml). Branch protection requires all of these to pass:

1. `mix format --check-formatted`
2. `mix compile --warnings-as-errors`
3. `mix credo --strict`
4. `mix sobelow --config` (accepted exceptions and their reasons are in `.sobelow-conf`)
5. `mix deps.audit` and `mix hex.audit`
6. The privacy gate: `mix test --only privacy`
7. No third-party assets: `mix test --only third_party_assets`
8. `mix coveralls`: the full suite with an 85% coverage floor
9. `mix dialyzer`
10. A Docker image build (no push)

`mix ci` runs the same gates locally. Dependabot watches mix and GitHub Actions.

## Browser checks

Every screen change is walked in a real browser before it is done, using BrowserHost on David's desktop. See [`CLAUDE.md`](CLAUDE.md) and `script/browser-check`.

## Licence

To be decided. The proposal is MIT for the code and CC BY 4.0 for the rubric. Until a licence is added, all rights are reserved. The fonts in `priv/static/fonts` are under the SIL Open Font License; their licence files sit beside them.
