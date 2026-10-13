# AI in Practice: rules for agents

Read `AGENTS.md` for general Phoenix and Elixir guidance. This file wins where they differ.

**Plan of record:** Slipdock board `ai-in-prac`. **Source of truth:** the PRD (wiki W-108) and the rubric (wiki W-106, copied to `priv/rubric/rubric.md`). Record any decision you make on the card you are working.

## Privacy (PRD §10): never break these

- Transcripts, answers and reports live **only in the memory of the session's process**. Never write them to disk, the database, ETS that outlives the session, or Logger, including in `inspect` output in error messages.
- The database holds link and usage data only: no candidate names, contact details or free text from a session.
- Link tokens appear only in URL paths. `AiInPracticeWeb.Plugs.RequestLogger` redacts them from request logs, and `:filter_parameters` (in `config/config.exs`) filters `token`, `url` and `redirect` params. Tokens must be 16 or more URL-safe characters so the redaction catches them.
- Routes that carry a token, assessment pages and report downloads go through the `:private` pipeline (`Cache-Control: no-store`, `X-Robots-Tag: noindex`).
- Tag tests that prove nothing leaks with `@tag :privacy`. CI runs them as a named step.

## Admin separation (PRD §11, §13.1)

- Admin routes live **only** on `AiInPracticeWeb.AdminRouter` (under `/admin`), served by `AiInPracticeWeb.AdminEndpoint`. Never add an admin route to the public router. `test/ai_in_practice_web/admin_endpoint_test.exs` checks that every admin path is a 404 on the public endpoint.
- Admin controllers, views and LiveViews use `:admin_controller`, `:admin_html` and `:admin_live_view` (from `AiInPracticeWeb`), so their `~p` paths are checked against the admin router.
- In production the admin listener binds to `ADMIN_IP` (the Tailscale address). `AiInPractice.AdminBind` refuses to boot if the address is missing or is `0.0.0.0` or `::`.

## Design system (PRD §13.2)

- Tokens, fonts and rules are in `assets/css/app.css`. Use its semantic classes. There is no Tailwind and there are no icons.
- Rules in place of boxes (3px ink rule for structure, 2px hairline for separators). Flush left on a 12px vertical unit; **nothing centred**; **no rounded corners**, shadows, gradients, chips, pills, icons, images or transitions.
- Source Serif 4 for language, IBM Plex Mono for data. Mono is **never capitals**.
- The accent (oxblood `#8a2a1e`) marks the one thing on a screen that is the point, **at most twice per screen**, never on thin rules or small type.
- Fonts are self-hosted in `priv/static/fonts`. **No third-party requests** from any page: no CDNs, no Google Fonts, no analytics.
- `test/ai_in_practice_web/design_system_test.exs` checks the stylesheet against these rules. Keep it passing; extend it when you add rules.

## Copy

Follow the PRD's vocabulary: never "interview", never "verified", no scores, no product language ("sign up", "pricing", "plan"). It is a framework and a conversation starter.

## Definition of done

Every card:

1. Tests for the new or changed code, in the same commit: the error and edge cases, not only the happy path. Assert outcomes.
2. `mix ci` is green (the same gates as `.github/workflows/ci.yml`).
3. Pushed to `main`, and CI is green on GitHub.
4. The card says which tests were added.
5. Any change to the rubric or the prompts (`priv/rubric/rubric.md`, `lib/ai_in_practice/assessment/*_prompt.ex`) needs a green `mix eval.gate` run (see `eval/README.md`), recorded on the card.

**Any card that changes a screen**, in addition:

6. A BrowserHost walk-through of the changed screens from David's desktop (`bigwhite`), using `script/browser-check`: the happy path **and at least one error state**.
7. Check the design rules by eye in the screenshot: the fonts load, nothing is centred, no rounded corners, the accent is used at most twice.
8. Summarise the steps on the card with a screenshot or a snapshot excerpt.

### Browser checks

The dev server is reachable from `bigwhite` over Tailscale. `dedev` does not resolve on bigwhite, so use the IP:

```sh
ADMIN_IP=100.88.155.65 mix phx.server          # public :4100 on all interfaces, admin :4101 on Tailscale
curl http://bigwhite:9001/api/health           # BrowserHost is up
script/browser-check open http://100.88.155.65:4100/
script/browser-check snapshot
script/browser-check errors                    # console errors, including CSP violations
script/browser-check shot home                 # tmp/browser/home.png (git-ignored)
script/browser-check open http://100.88.155.65:4101/admin
```

The session is always `ai-in-practice`. Port 4000 is taken on dedev, so dev uses 4100 and 4101.

**Release gate (before each deploy, once the journey exists):** admin issues a recruiter link, the recruiter mints a candidate link, the candidate completes a short session with the fake LLM (a dev-only flag), and both PDFs download. Walk it in BrowserHost and record it on the deploy card.
