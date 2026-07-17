# dotnet-senior-skills

Senior-level .NET code-review rules that coding agents (Claude Code, Cursor, GitHub Copilot) load automatically.

Agents write plausible C# that a senior rejects in review: captive dependencies, three collection Includes, async void, entities leaking through the API boundary. These 25 skills encode the rejections - with hard thresholds and before/after C#, not principles.

## Install

One command, from a clone, into your project:

```sh
git clone https://github.com/Sarmkadan/dotnet-senior-skills
./dotnet-senior-skills/install.sh /path/to/your/project
```

Or per tool:

```sh
# Claude Code
cp -r dotnet-senior-skills/skills/. your-project/.claude/skills/
# Cursor
cp dotnet-senior-skills/.cursor/rules/*.mdc your-project/.cursor/rules/
# GitHub Copilot
cp dotnet-senior-skills/.github/copilot-instructions.md your-project/.github/
```

## Skills

| Skill | Covers |
| --- | --- |
| [ef-core-migration-safety](skills/ef-core-migration-safety/SKILL.md) | Destructive migrations, expand/contract, shadow properties, deploy order |
| [ef-core-query-review](skills/ef-core-query-review/SKILL.md) | N+1, cartesian explosion, AsNoTracking, projection, client-side eval |
| [async-await-pitfalls](skills/async-await-pitfalls/SKILL.md) | Sync-over-async, async void, ValueTask, CancellationToken flow |
| [api-layer-boundaries](skills/api-layer-boundaries/SKILL.md) | Controller/service/repository responsibilities, DTO vs entity leakage |
| [dependency-injection-lifetimes](skills/dependency-injection-lifetimes/SKILL.md) | Captive dependencies, scopes in singletons, HttpClient registration |
| [nullable-reference-discipline](skills/nullable-reference-discipline/SKILL.md) | Annotation honesty, null-forgiveness audit, EF interaction |
| [exception-and-result-strategy](skills/exception-and-result-strategy/SKILL.md) | Throw vs Result, catch rules, what never to swallow |
| [solid-review-checklist](skills/solid-review-checklist/SKILL.md) | SOLID as concrete C# review triggers, not definitions |
| [configuration-and-secrets](skills/configuration-and-secrets/SKILL.md) | Options pattern, startup validation, secret storage, layering |
| [testing-strategy](skills/testing-strategy/SKILL.md) | What to test per layer, why mocking DbContext is a smell |
| [performance-review](skills/performance-review/SKILL.md) | Allocations, spans, pooling, caching, when to care at all |
| [security-review-dotnet](skills/security-review-dotnet/SKILL.md) | AuthZ vs authN, IDOR, mass assignment, SQL injection, deserialization |
| [datetime-and-time-handling](skills/datetime-and-time-handling/SKILL.md) | DateTimeOffset vs DateTime, UTC discipline, TimeProvider, DST traps |
| [disposal-and-resource-lifetime](skills/disposal-and-resource-lifetime/SKILL.md) | IDisposable ownership, IAsyncDisposable, what never to dispose, finalizer rules |
| [logging-and-observability](skills/logging-and-observability/SKILL.md) | Structured templates, levels, what never to log, correlation, metrics vs logs |
| [concurrency-and-shared-state](skills/concurrency-and-shared-state/SKILL.md) | lock discipline, SemaphoreSlim, ConcurrentDictionary traps, Channels, bounded parallelism |
| [background-work-and-hosted-services](skills/background-work-and-hosted-services/SKILL.md) | BackgroundService loops, scopes, graceful shutdown, queue consumers, outbox |
| [serialization-review](skills/serialization-review/SKILL.md) | System.Text.Json options, contract evolution, safe polymorphism, streaming |
| [http-resilience-and-outbound-calls](skills/http-resilience-and-outbound-calls/SKILL.md) | IHttpClientFactory, timeouts, retries vs idempotency, circuit breakers |
| [domain-modeling-and-primitives](skills/domain-modeling-and-primitives/SKILL.md) | Primitive obsession thresholds, value objects, records vs classes, invariants |
| [ef-core-transactions-and-concurrency](skills/ef-core-transactions-and-concurrency/SKILL.md) | Transaction boundaries, rowversion tokens, lost updates, execution strategies |
| [collections-and-equality](skills/collections-and-equality/SKILL.md) | Collection exposure, Equals/GetHashCode contract, key immutability, comparers |
| [middleware-and-pipeline-order](skills/middleware-and-pipeline-order/SKILL.md) | Pipeline ordering, auth placement, custom middleware pitfalls, filters vs middleware |
| [globalization-and-culture](skills/globalization-and-culture/SKILL.md) | InvariantCulture boundaries, StringComparison, Turkish-I, localization edges |
| [memory-leaks-and-diagnostics](skills/memory-leaks-and-diagnostics/SKILL.md) | Event/timer/CTS leaks, unbounded caches, LOH, gcdump-driven diagnosis |

## Sample rules

Verbatim from the skill files - this is the level of specificity throughout:

> Two or more collection `Include`s on the same level multiply row counts. Use `AsSplitQuery()` [...] or split into separate targeted queries. One collection Include is fine; two is a review comment; three is a rejection.

> A service must not depend on anything with a SHORTER lifetime. Singleton -> Scoped is the captive dependency: the singleton captures the first scope's instance forever. [...] Symptoms in production: `ObjectDisposedException: Cannot access a disposed context`, cross-request data bleed.

> Old app code and new schema coexist during a rolling deploy. Never ship a migration the *previous* app version cannot run against.

> An empty catch block is a rejection, no discussion. Minimum viable swallow is `catch (SpecificException ex) { _logger.LogWarning(ex, "context, deliberately ignored because X"); }` - the "because X" is mandatory.

> Flag a SOLID issue only with the concrete cost attached: "this switch is duplicated in X and Y, next format touches both" - not "violates OCP". If you cannot name the cost, it is not a finding.

> **Retry only idempotent things.** GET/PUT/DELETE by spec; POST only when the API supports idempotency keys - and then send one. Retrying a non-idempotent POST on timeout is how customers get charged twice: the timeout does not mean the first attempt failed, it means you do not know.

> Read-modify-write without a concurrency token means last-writer-wins: two users load the same row, both save, one edit silently vanishes. No exception, no log - discovered weeks later as "the system lost my changes".

## License

MIT - see [LICENSE](LICENSE).
