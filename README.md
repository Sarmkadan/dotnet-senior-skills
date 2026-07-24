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
| [api-layer-boundaries](skills/api-layer-boundaries/SKILL.md) | Enforce layering in ASP.NET Core services - what belongs in controllers, application services, and repositories; DTO vs entity leakage; where transactions and validation live. Use when reviewing or designing API endpoints and service classes. |
| [async-await-pitfalls](skills/async-await-pitfalls/SKILL.md) | Review C# async/await code for deadlocks, sync-over-async, async void, ValueTask misuse, fire-and-forget, and CancellationToken propagation. Use when writing or reviewing any async C# code. |
| [background-work-and-hosted-services](skills/background-work-and-hosted-services/SKILL.md) | Review .NET background processing - BackgroundService loops, scoped dependency resolution, graceful shutdown, timers, queue consumption, and outbox patterns. Use when reviewing IHostedService, BackgroundService, recurring jobs, or queue consumers. |
| [collections-and-equality](skills/collections-and-equality/SKILL.md) | Review .NET collection and equality code - choosing collection types, exposure through APIs, GetHashCode/Equals contracts, dictionary key safety, and comparer usage. Use when reviewing collection-typed members, equality implementations, or LINQ set operations. |
| [concurrency-and-shared-state](skills/concurrency-and-shared-state/SKILL.md) | Review .NET concurrency - lock discipline, Interlocked, concurrent collections, SemaphoreSlim for async mutual exclusion, Channels, and Parallel.ForEachAsync. Use when reviewing shared mutable state, locks, or parallel code. |
| [configuration-and-secrets](skills/configuration-and-secrets/SKILL.md) | Review .NET configuration handling - IOptions<T> vs raw IConfiguration access, secret material never in appsettings committed to git, user-secrets/env/KeyVault ordering, and redaction in logging. |
| [datetime-and-time-handling](skills/datetime-and-time-handling/SKILL.md) | Review .NET date/time code - DateTime vs DateTimeOffset, UTC discipline, TimeProvider for testability, timezone conversion, and scheduling pitfalls. Use when reviewing any code that touches DateTime, DateTimeOffset, timestamps, or scheduling. |
| [dependency-injection-lifetimes](skills/dependency-injection-lifetimes/SKILL.md) | Review .NET dependency injection registrations for captive dependencies, scoped-in-singleton bugs, IServiceProvider abuse, disposal issues, and HttpClient registration. Use when writing or reviewing DI container registrations or constructor injection. |
| [disposal-and-resource-lifetime](skills/disposal-and-resource-lifetime/SKILL.md) | Review IDisposable/IAsyncDisposable usage in .NET - what to dispose, what never to dispose, using patterns, the dispose pattern itself, and finalizer rules. Use when reviewing resource management, using statements, or classes owning disposable fields. |
| [domain-modeling-and-primitives](skills/domain-modeling-and-primitives/SKILL.md) | Review C# domain models - primitive obsession, value objects, records vs classes, enums vs polymorphism, invariant enforcement in constructors, and anemic model smells. Use when reviewing domain entities, value types, or business-logic placement. |
| [ef-core-migration-safety](skills/ef-core-migration-safety/SKILL.md) | Review EF Core migrations for data loss, downtime, and deploy-order hazards. Use when adding, reviewing, or applying EF Core migrations, or when a schema change must ship without downtime. |
| [ef-core-query-review](skills/ef-core-query-review/SKILL.md) | Review EF Core LINQ queries for N+1, cartesian explosion, tracking overhead, client-side evaluation, and over-fetching. Use when writing or reviewing any code that queries a DbContext. |
| [ef-core-transactions-and-concurrency](skills/ef-core-transactions-and-concurrency/SKILL.md) | Review EF Core write paths - transaction boundaries, optimistic concurrency tokens, lost updates, retry strategies vs user transactions, and multi-aggregate consistency. Use when reviewing SaveChanges patterns, transactions, or concurrent-write handling. |
| [exception-and-result-strategy](skills/exception-and-result-strategy/SKILL.md) | Decide when C# code should throw, when to return a Result type, what exceptions to define, and what must never be swallowed. Use when reviewing error handling, try/catch blocks, or designing failure contracts for services and APIs. |
| [globalization-and-culture](skills/globalization-and-culture/SKILL.md) | Review .NET culture-sensitivity bugs - parsing and formatting with invariant vs current culture, string comparison choices, the Turkish-I problem, and localization boundaries. Use when reviewing Parse/ToString/string comparison code or anything formatting numbers and dates. |
| [http-resilience-and-outbound-calls](skills/http-resilience-and-outbound-calls/SKILL.md) | Review outbound HTTP in .NET - IHttpClientFactory usage, timeouts, retries with idempotency awareness, circuit breakers, and response handling. Use when reviewing HttpClient code, Polly/resilience policies, or any service-to-service calls. |
| [input-validation-and-injection](skills/input-validation-and-injection/SKILL.md) | Enforce input validation and prevent injection at API boundaries - SQL injection, over-posting, unbounded queries, and unvalidated input. Use when reviewing controllers, endpoints, and data-access code. |
| [logging-and-observability](skills/logging-and-observability/SKILL.md) | Review .NET logging and observability - structured logging discipline, log levels, what not to log, correlation, exception logging, and metrics/tracing hooks. Use when reviewing ILogger usage, log statements, or diagnostics code. |
| [memory-leaks-and-diagnostics](skills/memory-leaks-and-diagnostics/SKILL.md) | Review .NET code for managed memory leaks - event handler leaks, static caches, timers, CancellationTokenRegistration, closure captures - and how to diagnose with dotnet-counters/gcdump. Use when reviewing long-lived objects, event subscriptions, or investigating memory growth. |
| [middleware-and-pipeline-order](skills/middleware-and-pipeline-order/SKILL.md) | Review ASP.NET Core pipeline configuration - middleware ordering, auth placement, exception handling position, CORS, short-circuiting, and custom middleware pitfalls. Use when reviewing Program.cs pipeline setup or custom middleware. |
| [nullable-reference-discipline](skills/nullable-reference-discipline/SKILL.md) | Enforce nullable reference type discipline in C# - annotation honesty, null-forgiveness audit, boundary validation, and EF Core interaction. Use when writing or reviewing C# code in nullable-enabled projects or migrating projects to nullable. |
| [performance-review](skills/performance-review/SKILL.md) | Review .NET code for allocation pressure, string handling, Span/pooling opportunities, LINQ costs, and caching - with explicit guidance on when performance work is and is not justified. Use when reviewing hot paths, optimizing .NET code, or evaluating performance claims. |
| [security-review-dotnet](skills/security-review-dotnet/SKILL.md) | Security review checklist for ASP.NET Core - authorization vs authentication, IDOR, mass assignment, SQL injection through raw SQL and EF, secrets exposure, and unsafe deserialization. Use when reviewing endpoints, data access, or anything handling user input or credentials. |
| [serialization-review](skills/serialization-review/SKILL.md) | Review .NET serialization - System.Text.Json configuration, contract evolution, polymorphism, streaming large payloads, and deserialization security. Use when reviewing JSON handling, serializer options, or API/message contracts. |
| [solid-review-checklist](skills/solid-review-checklist/SKILL.md) | Apply SOLID principles concretely to C# code review - real smells, thresholds, and refactors rather than abstract definitions. Use when reviewing class design, service structure, or interface changes in C#. |
| [testing-anti-patterns](skills/testing-anti-patterns/SKILL.md) | Review .NET test code for common anti-patterns - mocking DbContext, asserting implementation details, Task.Delay timing, missing cancellation tokens, and brittle assertions. Use when reviewing test PRs or designing test suites. |
| [testing-strategy](skills/testing-strategy/SKILL.md) | Decide what to test at each layer of a .NET service, when integration tests beat unit tests, why mocking DbContext is a smell, and what makes tests worth their maintenance cost. Use when writing tests, reviewing test PRs, or designing a test suite. |
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
