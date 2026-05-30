# ADR-0009: Build-time config for public-by-design SDK keys

* **Status:** Accepted — 2026-05-29
* **Decision Makers:** Ganesh
* **Supersedes:** —
* **Last reviewed:** 2026-05-29

## Context and Problem Statement

Steno integrates two third-party analytics SDKs: Sentry (crash reports) and PostHog (usage events, both opt-out). Each ships with an SDK "key" that the client app embeds:

- **Sentry DSN** — a URL containing a public identifier. Client apps put it in code by design.
- **PostHog Project API key** (`phc_*`) — a write-only ingestion key. PostHog docs say to embed it in client code.

Until this ADR, both keys were inlined as `private static let` constants in `Steno/Services/Analytics.swift`. This made GitGuardian and similar repo-scanning tools flag the repo, even though both vendors explicitly say these keys are public-by-design. The alert reads as a security issue when in fact it's a hygiene issue — but the alert is real and creates noise.

A separate concern: setting the precedent of "literal SDK keys in code" makes it easy for the *next* SDK integration to accidentally inline a key that is **not** public-by-design (a real secret). Defense in depth wants a single answer to "where does an SDK key live?" — and that answer should not be "in Swift source."

## Decision Drivers

- **Hygiene over security.** The keys are public-by-design; embedding them is not a security failure. But removing them from source removes the secret-scanner alert and stops setting the wrong precedent.
- **No backend dependency.** Steno is a client-only app. Adding a server proxy to keep these keys server-side is out of scope.
- **The key still ends up in the shipped `.dmg`.** Anything in `Bundle.main.infoDictionary` is readable by `strings(1)` on the binary. We're not improving security against a determined attacker; we're closing the GitHub-visible surface.
- **Distinct from real secrets.** Personal API Keys (`phx_*`), Anthropic/OpenAI keys (`sk-*`), Apple App Store Connect API keys, signing certs — those are *secrets*. They never go in any committed file, ever. The xcconfig pattern in this ADR is for public-by-design keys only.

## Considered Options

### Option 1: Status quo — inline as `private static let`

* **Bad:** GitGuardian / GitHub secret scanner flag it.
* **Bad:** Sets the precedent that "SDK keys live in .swift code."

### Option 2: Read from a gitignored `Steno.xcconfig` via Info.plist substitution

Keys live in `Steno.xcconfig` (gitignored). `Steno.xcconfig.example` is committed as the template. `project.yml` references the xcconfig via `configFiles:`. `Steno/Info.plist` has `<key>PostHogKey</key><string>$(POSTHOG_API_KEY)</string>` style entries. `Bundle.main.infoDictionary?["PostHogKey"] as? String` reads at runtime.

* **Good:** Repo contains zero literal keys.
* **Good:** Secret scanners stop firing on `phc_*` and Sentry DSN patterns.
* **Good:** New collaborators get a clear template (`Steno.xcconfig.example`).
* **Neutral:** Keys still end up in the built `.app`'s Info.plist. No security improvement against binary inspection.
* **Neutral:** Local-only friction — first-time setup needs `cp Steno.xcconfig.example Steno.xcconfig` and editing.

### Option 3: Read from environment variables at build time

Same idea but using `$(POSTHOG_API_KEY)` resolved from the shell environment instead of xcconfig.

* **Good:** No file on disk — keys come from shell env or CI secret.
* **Bad:** Local-dev friction is higher (need to source a `.env` or set env vars before each `xcodebuild`).
* **Bad:** No template/example mechanism — newcomers have to be told what vars exist.

### Option 4: Server proxy

Client makes API calls to your backend; backend proxies to Sentry/PostHog with the real keys.

* **Good:** Real security.
* **Bad:** Adds infrastructure that doesn't exist. Out of scope for a client-only app.

## Decision Outcome

**Selected: Option 2 — gitignored `Steno.xcconfig` + Info.plist substitution.**

### File layout

| File | Status | Purpose |
|---|---|---|
| `Steno.xcconfig` | **gitignored** | Real key values. First-time setup: `cp Steno.xcconfig.example Steno.xcconfig` and edit. |
| `Steno.xcconfig.example` | committed | Template with placeholder values. Documents the pattern + the `$()` URL workaround. |
| `Steno/Info.plist` | committed | Has `$(POSTHOG_API_KEY)` and `$(SENTRY_DSN)` placeholders. Xcode substitutes at build. |
| `project.yml` | committed | `configFiles: { Debug: Steno.xcconfig, Release: Steno.xcconfig }` wires it up. |
| `Steno/Services/Analytics.swift` | committed | Reads `Bundle.main.infoDictionary?["PostHogKey"]` and `["SentryDSN"]`. If empty (missing xcconfig), SDK init becomes a no-op with a log message. |
| `.gitignore` | committed | Contains `Steno.xcconfig`. |

### xcconfig comment-delimiter workaround

xcconfig treats `//` as a comment delimiter even inside string values. URLs containing `//` (like the Sentry DSN) break unless the `//` is split with an empty `$()` substitution:

```
SENTRY_DSN = https:/$()/abc@xxx.ingest.sentry.io/123
```

This resolves at build time to the correct URL. Documented in `Steno.xcconfig.example`.

### Linter enforcement

The `no-inline-sdk-key` rule in `tools/lint-steno.swift` flags literal `phc_*`, `phx_*`, `sk-ant-*`, `sk-*`, and Sentry DSN URL patterns in `.swift` files. Any future SDK key that gets pasted into source fails the linter with the remediation hint "move to Steno.xcconfig, read from Bundle.main.infoDictionary, see ADR-0009."

### Rationale

- Single source of truth for "where do SDK keys live": Steno.xcconfig. Code reads from Bundle. Documented in this ADR.
- Closes the GitGuardian alert cleanly without rotation theatre.
- Sets the right precedent for the next SDK integration — the next developer (or Claude) sees the pattern and follows it.
- Empty-fallback in `Analytics.swift` means a fresh checkout without the xcconfig still builds + runs; analytics just don't initialize. Useful for CI and for contributors who don't need analytics.

### Consequences

**Good:**
- Repo contains zero literal SDK keys going forward. Secret scanners stay quiet.
- Linter prevents accidental re-introduction.
- The pattern is portable — any future SDK key goes through the same flow.

**Bad:**
- One additional first-time setup step (`cp Steno.xcconfig.example Steno.xcconfig` + edit).
- The xcconfig `//` workaround is a small piece of folklore newcomers have to learn.
- Built `.app` still contains the keys in its Info.plist. Anyone inspecting the binary sees them. The xcconfig pattern is hygiene, not security.

### Updates downstream

- `Steno.xcconfig` (gitignored) — local values.
- `Steno.xcconfig.example` (committed) — template + comments documenting the pattern.
- `Steno/Info.plist` — `PostHogKey` and `SentryDSN` entries with `$(VAR)` references.
- `project.yml` — `configFiles:` directive.
- `Steno/Services/Analytics.swift` — reads from Bundle.main.infoDictionary with empty-fallback no-op.
- `.gitignore` — adds `Steno.xcconfig`.
- `tools/lint-steno.swift` — `no-inline-sdk-key` rule.
- `AGENTS.md` — "SDK Keys" section pointing at this ADR.

## More Information

- [ADR-0008](0008-custom-linter.md) — the linter that enforces this rule.
- PostHog docs on Project API keys (public-by-design, embedded in client SDKs).
- Sentry docs on DSN format (the DSN is intended to be client-embedded).
