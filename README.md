# dotnet-senior-skills

Opinionated, senior-level .NET review and coding rules for AI coding agents - the things an experienced architect actually flags in code review, with concrete before/after C#. Shipped in three formats from one source: Claude Code skills, Cursor rules, and Copilot instructions.

| Skill | Covers |
| --- | --- |
| [ef-core-migration-safety](skills/ef-core-migration-safety/SKILL.md) | Destructive migrations, expand/contract, shadow properties, deploy order |
| [ef-core-query-review](skills/ef-core-query-review/SKILL.md) | N+1, cartesian explosion, AsNoTracking, projection, client-side eval |
| [async-await-pitfalls](skills/async-await-pitfalls/SKILL.md) | Sync-over-async, async void, ValueTask, CancellationToken flow |
| [api-layer-boundaries](skills/api-layer-boundaries/SKILL.md) | Controller/service/repository responsibilities, DTO vs entity leakage |
| [solid-review-checklist](skills/solid-review-checklist/SKILL.md) | SOLID as concrete C# review triggers, not definitions |
| [nullable-reference-discipline](skills/nullable-reference-discipline/SKILL.md) | Annotation honesty, null-forgiveness audit, EF interaction |
| [exception-and-result-strategy](skills/exception-and-result-strategy/SKILL.md) | Throw vs Result, catch rules, what never to swallow |
| [dependency-injection-lifetimes](skills/dependency-injection-lifetimes/SKILL.md) | Captive dependencies, scopes in singletons, HttpClient registration |
| [configuration-and-secrets](skills/configuration-and-secrets/SKILL.md) | Options pattern, startup validation, secret storage, layering |
| [testing-strategy](skills/testing-strategy/SKILL.md) | What to test per layer, why mocking DbContext is a smell |
| [performance-review](skills/performance-review/SKILL.md) | Allocations, spans, pooling, caching, when to care at all |
| [security-review-dotnet](skills/security-review-dotnet/SKILL.md) | AuthZ vs authN, IDOR, mass assignment, SQL injection, deserialization |

Install: Claude Code - copy `skills/` into your project's `.claude/skills/`. Cursor - copy `.cursor/rules/` into your repo. Copilot - copy `.github/copilot-instructions.md`.
