# AI in Practice

A framework from [DSC](https://dsc.net) for a conversation about how a senior person works with AI, published at `ai-in-practice.dsc.net`.

A 20 to 25 minute AI-led conversation produces two written reports: a private, developmental one for the person, and a signed one they can choose to release to a recruiter, CEO or board member. **It is a conversation starter.** It gives no score, ranks no one and makes no decision about anyone. It is not a product: there is no sign-up, no pricing and no public access. Links are issued personally.

This repository holds the whole application and the rubric it assesses against, so anyone can check what it does and does not do with what people say.

## The rubric

[`priv/rubric/rubric.md`](priv/rubric/rubric.md) sets out the principles, the five areas (understanding, personal use, applying AI to the business, leading adoption, attitude), how expectations change by role, and what each report contains. Its `version` front matter is shown in every page footer and report.

## Privacy design, and how the code shows it

| Claim | Where to check |
|---|---|
| The conversation is held only in server memory for the session, then discarded. It is never written to disk, the database or logs. | The assessment engine (in progress). CI's **privacy gate** runs every test tagged `:privacy`. |
| The database holds link and usage data only: tokens, link type, quota, role group, status and timestamps. Nothing that identifies a candidate. | `priv/repo/migrations` |
| Link tokens never reach the logs. | `lib/ai_in_practice_web/plugs/request_logger.ex` redacts them from request paths. `config/config.exs` filters them from logged params. Tests: `test/ai_in_practice_web/plugs/request_logger_test.exs` |
| Assessment pages and report downloads are never cached or indexed, and links do not leak through the `Referer` header. | `lib/ai_in_practice_web/plugs/security_headers.ex` |
| No third-party requests: fonts are self-hosted and there is no analytics. | `priv/static/fonts`, `test/ai_in_practice_web/design_system_test.exs` |
| Admin is reachable only over Tailscale, on a separate listener with its own router. | `lib/ai_in_practice_web/admin/`, `lib/ai_in_practice/admin_bind.ex`, `test/ai_in_practice_web/admin_endpoint_test.exs` |

Third parties in the data path: Cloudflare (which fronts the site and terminates TLS), and OpenRouter and the underlying model provider (zero data retention).

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

Production needs `DATABASE_PATH`, `SECRET_KEY_BASE`, `PHX_HOST` and `ADMIN_IP` (the host's Tailscale address). Optional: `ADMIN_PORT` (default 4001), `PORT` (default 4000), `OPENROUTER_MODEL`. The app refuses to start if `ADMIN_IP` is missing or is `0.0.0.0` or `::`.

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
