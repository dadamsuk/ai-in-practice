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
| Spoken answers: the recording is held in memory only, sent to David's transcription engine and dropped. It never touches disk (LiveView's default upload writer uses a temp file, so a custom writer keeps it in memory). The engine is asked for its local model and to keep nothing, and logs carry the status and latency only. | `lib/ai_in_practice_web/memory_upload_writer.ex`, `lib/ai_in_practice/transcriber/manuel.ex`. Tests: `test/ai_in_practice/transcriber/manuel_test.exs`, `test/ai_in_practice_web/live/assessment_voice_test.exs` |
| Answers are treated as data, never as instructions; an attempt to steer the assessment is ignored and noted in the assessor report. | `lib/ai_in_practice/assessment/conversation_prompt.ex`, `report_prompt.ex`, `report.ex` |
| The database holds link and usage data only: token hashes, link type, the recruiter firm and contact (entered by DSC), quota, role group, status and timestamps, plus the curated reading list. Nothing that identifies a candidate. | `priv/repo/migrations`, `lib/ai_in_practice/links.ex`. Test: `test/ai_in_practice/links/schema_test.exs` checks no column could hold session data |
| Link tokens are 256 random bits, and only their SHA-256 hash is stored, so the database alone cannot open a link. A new link's address is shown once. | `lib/ai_in_practice/links/token.ex` |
| A recruiter's labels for their candidate links (e.g. initials) stay in their own browser and are never sent to the server. | `lib/ai_in_practice_web/live/recruiter_live.ex`. Test: `test/ai_in_practice_web/live/recruiter_live_test.exs` |
| Link tokens never reach the logs, nor do answers or the session id that report downloads use. | `lib/ai_in_practice_web/plugs/request_logger.ex` redacts them from request paths. `config/config.exs` filters `token`, `answer` and `session` from logged params. Tests: `test/ai_in_practice_web/plugs/request_logger_test.exs`, `test/ai_in_practice_web/live/assessment_privacy_test.exs` |
| Reports are downloaded from the live session's memory, and from nowhere else. Once the page is closed or the hour is up, there is nothing to download. | `lib/ai_in_practice_web/controllers/report_controller.ex`. Test: `test/ai_in_practice_web/controllers/report_controller_test.exs` |
| Report PDFs are made in memory when downloaded and never written anywhere. The signed copy of the assessor report holds only what it visibly says: no internal levels or confidence, and no link id. | `lib/ai_in_practice/reports/pdf.ex` (Typst runs in memory, with the report passed as an in-memory file), `lib/ai_in_practice/reports/payload.ex`. Tests: `test/ai_in_practice/reports/payload_test.exs`, `pdf_test.exs` |
| An unusable link says nothing about itself: unknown, withdrawn, used and completed links get the same page. | `lib/ai_in_practice_web/plugs/usable_link.ex`. Test: `test/ai_in_practice_web/plugs/usable_link_test.exs` |
| Assessment pages and report downloads are never cached or indexed, and links do not leak through the `Referer` header. | `lib/ai_in_practice_web/plugs/security_headers.ex` |
| No third-party requests: fonts are self-hosted and there is no analytics. | `priv/static/fonts`, `test/ai_in_practice_web/design_system_test.exs` |
| Admin is reachable only over Tailscale, on a separate listener with its own router. | `lib/ai_in_practice_web/admin/`, `lib/ai_in_practice/admin_bind.ex`, `test/ai_in_practice_web/admin_endpoint_test.exs` |
| The privacy notice and terms say the same as this table: what is kept and never kept, the third parties, and that the framework is a conversation starter, never an automated decision. They are linked from the start screen and every public footer, and open in a new tab so reading them cannot end a conversation. | `lib/ai_in_practice_web/controllers/page_html/privacy.html.heex`, `terms.html.heex` (at `/privacy` and `/terms`). Test: `test/ai_in_practice_web/controllers/legal_pages_test.exs` |
| Candidate- and recruiter-facing copy never says "interview" or "verified", has no scores, pass marks or tests of the person, and no product language. | `test/support/vocabulary_guard.ex` scans every public template, `Reports.Content` and the report's Typst file. Test: `test/ai_in_practice_web/vocabulary_test.exs` |

Third parties in the data path: Cloudflare (which fronts the site and terminates TLS), and OpenRouter and the underlying model provider (zero data retention). Spoken answers go to David's own transcription engine over Tailscale, not to a third party.

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

Set `FAKE_TRANSCRIBER=1` to offer voice in development with a fake transcriber, which turns every recording into the same sentence. `no_speech` and `unavailable` fail every recording in those ways, and `down` keeps voice off. To use the real engine instead, set `TRANSCRIPTION_SERVICE_URL` and `TRANSCRIPTION_SERVICE_KEY`. The microphone needs a secure context, which `http://100.88.155.65:4100` is not, so in BrowserHost give the page a synthetic microphone with `script/browser-check eval` (a WebAudio stream in place of `navigator.mediaDevices.getUserMedia`).

## Evaluation

`eval/` holds the persona harness (PRD §14): a second model plays a synthetic person from a YAML file in `eval/personas/` and talks to the real engine. Each persona runs several times, and the summary shows how far the internal levels spread between runs, how far they sit from the persona's true levels, and what each session cost and how long it took. It costs real inference, so a budget guard caps calls and spend per run. Transcripts and reports go to `~/ai-in-practice-eval/`, never into the repository. The harness is compiled in dev and test only. See [`eval/README.md`](eval/README.md).

```sh
mix eval.personas --fake                                  # free dry run
OPENROUTER_API_KEY=... mix eval.personas --runs 3 --max-spend 2
```

## The candidate journey

`/a/TOKEN` is one LiveView, `lib/ai_in_practice_web/live/assessment_live.ex` (PRD §7):

1. **Start screen.** What this is and what it is not, the time it takes, one attempt, anonymising, how answers are handled, and (for a recruiter's link) who sent it and what they can see. The role group is shown, or chosen for an individual link. When the transcription engine is configured and answers, it also offers to begin with spoken answers (v2). Opening it does not use the link.
2. **Conversation.** One question at a time, with focus moved to each new question. Paste and drop are refused in the answer box (dictation still works). A quiet five-segment progress rule. "Finish early", with a confirmation. The browser warns before the page is closed. **Voice:** record and stop controls above the answer box (MediaRecorder, a five-minute limit). The recording goes to the transcriber (`AiInPractice.Transcriber`, David's engine via `Transcriber.Manuel`), and the text is added to the answer box for the person to correct before sending. Questions stay on screen only. Every failure (microphone refused, no words heard, unusable recording, engine unavailable) says so, and typing is always there. The reports' header says whether answers were typed or spoken.
3. **Generating**, then **reports**: both reports on screen (the candidate's, then the assessor's), with a download for each and a prominent warning that nothing is kept.

The link is used up when the first question arrives and completed when the reports arrive. **Error screens:** temporarily unavailable (before the first question, with the link unused), a failure mid-conversation, reports that could not be written, no answers, and reports past their hour. The screens after the link was used say who can send a new one: the recruiter, or David for an individual link.

**Reconnecting:** if the connection drops, the page reattaches to the same session for up to two minutes. Reloading or closing the page ends the conversation.

## Reports and signatures

Both reports download as A4 PDFs in the printed-specification register: a running head rule, a serif body, mono labels, hairlines between areas, and a running foot with the role group, date and versions. Every page of the assessor report also carries the statement that it is a conversation starter, that identity is not checked, and that it is one input to human judgement. They are rendered with [Typst](https://typst.app) (the `typst` package, in memory) from [`priv/reports/report.typ`](priv/reports/report.typ), using the same content the screen shows (`lib/ai_in_practice/reports/content.ex`). The fonts (Source Serif 4 and IBM Plex Mono, OFL) are embedded from `priv/fonts/`. **PDFs are made when downloaded and never stored.**

**The assessor report is signed** with Ed25519 (`lib/ai_in_practice/reports/signing.ex`). The PDF has an attached file, `ai-in-practice-signed-report.json`, that holds:

```json
{"alg": "Ed25519", "kid": "…", "payload": {…the report…}, "signature": "…"}
```

`payload` is what the report says (`lib/ai_in_practice/reports/payload.ex`): the header facts, versions, summary, areas with quotes, what to explore next and the questions to ask. It never holds the internal levels or confidence. `signature` is the Base64 Ed25519 signature over the payload as canonical JSON: keys sorted by their UTF-8 bytes at every depth, no whitespace, and no floats (`lib/ai_in_practice/reports/canonical.ex`). Anyone can compare the signed payload with the visible PDF, so any edit to the PDF shows up as a mismatch. The candidate's own report is not signed.

**The check page**, [`/check`](https://ai-in-practice.dsc.net/check), lets anyone upload an assessor report PDF. It checks the signature (`lib/ai_in_practice/reports/check.ex`) and shows the signed content in full, laid out as the report is, so the reader can compare it with the PDF they hold. A match says the report is genuine and unedited; the page says plainly that it says nothing about who took part. The upload is read in memory by `AiInPracticeWeb.Plugs.CheckUpload` instead of Plug's multipart parser, which would write it to a temporary file; it is limited to 5 MB, never a request param (so never logged), and dropped with the request. The path avoids "verify", per the PRD's vocabulary. `mix signing_key verify` runs the same check.

**Public keys** are published at [`/.well-known/ai-in-practice/signing-keys.json`](https://ai-in-practice.dsc.net/.well-known/ai-in-practice/signing-keys.json): the current key and any retired ones, each with its `kid` (the first 16 hex digits of the SHA-256 of the public key). The production key is listed there, rather than here, so this file cannot drift from it.

```sh
mix signing_key new                  # a new key: the REPORT_SIGNING_KEY line, its public key and id
mix signing_key public               # the public keys this server publishes
mix signing_key verify FILE.pdf      # check an assessor report's signature

bin/signing_key verify FILE.pdf      # the same on a release (runs without the server)
```

**Rotating the key:** set the new key in `REPORT_SIGNING_KEY` and add the old public key to `REPORT_SIGNING_RETIRED_KEYS` (comma-separated), so reports it signed still verify. Production refuses to start without a valid key. In development and tests an ephemeral key is made at each start.

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

Production needs `SECRET_KEY_BASE`, `PHX_HOST` (the public host name), `OPENROUTER_API_KEY`, `ADMIN_IP` (the host's Tailscale address) and `REPORT_SIGNING_KEY` (from `bin/signing_key new`). `DATABASE_PATH` is needed outside the Docker image, which defaults it to `/data/ai_in_practice.db`. Optional: `PUBLIC_IP` (the public listener's bind address, default every interface; `127.0.0.1` behind a Cloudflare Tunnel), `PORT` (default 4000), `ADMIN_PORT` (default 4001), `OPENROUTER_MODEL`, `REPORT_SIGNING_RETIRED_KEYS`, and `TRANSCRIPTION_SERVICE_URL` with `TRANSCRIPTION_SERVICE_KEY` (David's transcription engine, e.g. `http://bigwhite:8765`; without both, voice is not offered) and `TRANSCRIPTION_SERVICE_MODEL` (default `parakeet`, the engine's local model). The app refuses to start if any required one is missing, if `ADMIN_IP` is `0.0.0.0` or `::`, or if `REPORT_SIGNING_KEY` is invalid.

## Running the release image

```sh
docker build --build-arg GIT_SHA=$(git rev-parse HEAD) -t ai-in-practice .
docker run -d --init --network host -v ai-in-practice-data:/data --env-file /etc/ai-in-practice/env ai-in-practice
```

The SQLite database (links and usage only) lives on the `/data` volume, and migrations run on boot. Host networking lets the admin listener bind to the host's Tailscale address. Report PDFs are rendered by Typst inside the release, so the image needs no browser.

The report PDF tests read the text back with `pdftotext` (poppler-utils), so install it to run the suite.

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

## Releases and deploys

[`.github/workflows/cd.yml`](.github/workflows/cd.yml) publishes the release image to GHCR only after every CI gate has passed on a push to `main` or of a `v*` tag. Pull requests and red runs publish nothing.

- `ghcr.io/dadamsuk/ai-in-practice:<full sha>` for every green push, and `:main` for green `main`
- `:<version>` for a tag (`v1.2.0` publishes `1.2.0`), with a GitHub release

**Before tagging a release**, run the evaluation gate: Actions → `eval` → Run workflow ([`.github/workflows/eval.yml`](.github/workflows/eval.yml), which needs the `OPENROUTER_API_KEY` repository secret), or `mix eval.gate` locally. It runs ten fixed personas once each against the real model (about $0.20) and fails if reports stop validating, if internal levels drift from [`eval/baseline.json`](eval/baseline.json), if the manipulation note goes missing, or if a question names a level. **Any change to the rubric or the prompts needs a green gate run before release.** After a deliberate change that moves levels, rerun the full persona set and reset the baseline (`mix eval.gate --write-baseline <summary.json>`) in the same commit as the change.

Deploy by SHA tag, then run the post-deploy check against the live site:

```sh
script/smoke https://ai-in-practice.dsc.net <sha> http://<server public IP>:4001/admin
```

It checks that the footer shows that SHA; that assessment, recruiter and report URLs are `no-store` and `noindex`; that a same-origin CSP is set; that no page carries a third-party or Cloudflare-injected script; that the LiveView websocket upgrades from the site's own origin and is refused from another; that `/admin` is a 404 on the public site; and that each admin URL given cannot be reached. Any `FAIL` means roll back to the previous SHA tag.

How the server, Cloudflare and OpenRouter must be set up is on DSC's wiki: [hosting requirements (W-1665)](https://app.slipdock.us/boards/72/wiki/ai-in-practice-hosting-requirements). Deploys, rollback, the signing and OpenRouter keys, and backups are in the [runbook (W-1666)](https://app.slipdock.us/boards/72/wiki/ai-in-practice-runbook).

## Browser checks

Every screen change is walked in a real browser before it is done, using BrowserHost on David's desktop. See [`CLAUDE.md`](CLAUDE.md) and `script/browser-check`.

## Licence

To be decided. The proposal is MIT for the code and CC BY 4.0 for the rubric. Until a licence is added, all rights are reserved. The fonts in `priv/static/fonts` are under the SIL Open Font License; their licence files sit beside them.
