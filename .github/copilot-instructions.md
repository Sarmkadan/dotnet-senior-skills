# .NET Senior Engineering Rules

Condensed rules for this codebase. Full versions with rationale and examples live in `skills/`.

## EF Core

- Read-only queries: `AsNoTracking()` or project into DTOs with `Select` - never materialize full entities to build a DTO.
- Two or more collection `Include`s on one level = cartesian explosion; use `AsSplitQuery()` or separate queries.
- No queries inside loops; no `ToList()/AsEnumerable()` followed by more LINQ operators (moves filtering into memory).
- `Skip/Take` always with `OrderBy` on a unique key.
- Migrations: grep for `DropColumn/DropTable/AlterColumn` and read the SQL before merging. Renames must be `RenameColumn`, not drop+add. Required columns arrive in two releases: nullable + backfill, then NOT NULL. Never run `Database.Migrate()` at startup in multi-instance deployments. Applied migrations are immutable.
- A migration adding a column you did not add to the model is a shadow-property bug - fix the relationship configuration.

## Async

- Never `.Result`, `.Wait()`, or `.GetAwaiter().GetResult()` on incomplete tasks - async all the way up.
- `async void` only for event handlers; flag async lambdas passed to `Action` parameters.
- `ConfigureAwait(false)` in library code; not required in ASP.NET Core app code.
- Every async service method takes and forwards a `CancellationToken` (last parameter). Use `CancellationToken.None` explicitly for must-complete commit phases.
- Await a `ValueTask` exactly once; default public APIs to `Task`.
- No `_ = Task.Run(...)` fire-and-forget in request handlers - enqueue to a `BackgroundService` with a fresh `IServiceScope` per unit of work.
- One `DbContext` is never used concurrently (`Task.WhenAll` over two queries on one context is a bug).

## Layering

- Controllers: bind, call one application-service method, map to response. No DbContext, no business conditionals, no try/catch (a global `IExceptionHandler` owns error mapping).
- Never accept or return EF entities at the HTTP boundary. Request DTOs contain only client-settable fields; server-owned fields (id, owner, role, timestamps, state) are never bound from input.
- Application services own the transaction boundary (one commit per use case) and never return `IQueryable` or tracked entities. No `HttpContext` below the API layer - abstract as `ICurrentUser`.
- Reference direction: API -> Application -> Domain <- Infrastructure. Interfaces live with the consumer, not the implementation.

## Errors

- Throw for broken invariants and infrastructure failure; return a Result for expected domain outcomes the caller branches on. If the caller would catch to control flow, it should be a return value.
- `catch (Exception)` only in global middleware, message-consumer loops, and background-service loops. Empty catch blocks are rejected. `throw;`, never `throw ex;`.
- Never swallow `OperationCanceledException` on requested cancellation, or failures after a commit/side effect.
- Exception messages include the identifiers involved. No exception details in production response bodies.

## DI

- Never inject scoped services (DbContext) into singletons - use `IServiceScopeFactory` with one scope per unit of work. Enable `ValidateScopes` and `ValidateOnBuild` in all environments.
- Default to scoped; singleton only for verified-stateless thread-safe services. Transient `IDisposable` never resolved from the root provider.
- No `IServiceProvider` service-location in business code. `HttpClient` only via `IHttpClientFactory`/typed clients (typed clients not injected into singletons).
- Constructors assign fields; no I/O in constructors.

## Configuration and secrets

- No secrets in code or any git-tracked file; user-secrets locally, a secret store in production. Rotate anything that touched a commit.
- Services inject `IOptions<T>`, never `IConfiguration`. Every options class: `BindConfiguration` + validation + `ValidateOnStart()`.
- Deploy-time overrides via environment variables (`Section__Key`), not custom mechanisms.

## Nullability

- `<Nullable>enable</Nullable>` with nullable warnings as errors. `= null!` only for EF navigations and framework hooks; prefer `required`.
- Justify every `!`; validate data at trust boundaries regardless of annotations. FK and navigation nullability must agree.

## Testing

- Domain logic: exhaustive unit tests. Queries/mappings/migrations: integration tests on the real engine via Testcontainers. HTTP wiring: `WebApplicationFactory`.
- Never mock `DbSet`/DbContext and avoid the InMemory provider - mock a repository interface you own, or test against the real database.
- Assert outcomes over interactions; builders over copy-pasted setup; inject `TimeProvider` for determinism. Bug fixes ship with the regression test that fails without the fix.

## Performance

- Optimize only profiled hot paths; eliminate I/O (N+1, missing cache) before shaving allocations.
- Hot paths: no LINQ chains per item, no closures, structured logging templates (never interpolation into log calls), `Span`/`ArrayPool` for transient buffers (return in `finally`), pre-size collections, dictionary lookups instead of `Contains` in loops.
- Bound every cache; cache DTOs, never tracked entities. Performance PRs include before/after measurements.

## Security

- `[Authorize]` is not enough: every endpoint taking an id needs an ownership/tenancy predicate in the query; return 404, not 403, for unowned resources. Deny-by-default fallback policy; audit every `IgnoreQueryFilters()`.
- Raw SQL only via `FromSql`/interpolated parameter forms or explicit parameters; identifiers via allowlist. `FromSqlRaw` with concatenation is rejected.
- No `BinaryFormatter`; no polymorphic deserialization driven by type names in untrusted input. Uploads: allowlist content, server-generated names, never trust client paths.
- Passwords only through Identity/`PasswordHasher<T>`. No tokens/passwords in logs.

## Time

- `DateTimeOffset` for instants (stored UTC), `DateOnly` for calendar dates, local time + IANA timezone id for future local events. Never `DateTime.Now` in server code.
- Inject `TimeProvider` for any logic branching on "now"; read the clock once per operation. Elapsed time via `Stopwatch`/`GetTimestamp`, never subtracting wall-clock reads.
- Convert to user timezones only at the presentation edge; no arithmetic on local times across DST. Schedule recurring jobs in UTC or with an explicit DST policy.

## Disposal

- Creator disposes (`using`/`await using`); injected disposables belong to the container - never dispose them, and don't implement `IDisposable` just to dispose injected fields.
- Prefer `IAsyncDisposable` when cleanup does I/O; no `GetAwaiter().GetResult()` bridges in `Dispose`.
- No finalizers on managed-only classes; unmanaged handles via `SafeHandle`. `Dispose` is idempotent and never throws.

## Logging

- Message templates with PascalCase placeholders, never interpolated strings into loggers. Exception object as the first argument; log each exception at exactly one boundary.
- Levels: 1-2 Information lines per successful request; Warning only if actionable; every Error is a potential alert. No secrets, tokens, or destructured DTOs carrying credentials in logs.
- `BeginScope` for ambient ids; `[LoggerMessage]` source-gen on hot paths; counters via `Meter`, not log-grepping.

## Concurrency

- Prefer removing shared mutable state over locking it. `lock` on a private readonly gate; no I/O inside locks; async mutual exclusion via `SemaphoreSlim(1,1)`.
- Counters via `Interlocked`; one-time init via `Lazy<T>`. `ConcurrentDictionary.GetOrAdd` factories may race - wrap side-effecting factories in `Lazy<T>`.
- Producer-consumer via bounded `Channel<T>` with a deliberate `FullMode`. Batch parallelism via `Parallel.ForEachAsync` with explicit `MaxDegreeOfParallelism` - never unbounded `Task.WhenAll` over large collections.

## Background work

- `ExecuteAsync` loops catch per iteration, filter `OperationCanceledException` on shutdown, and never let one failure end the loop. `PeriodicTimer` loops, not `System.Threading.Timer` callbacks.
- One `IServiceScope` per unit of work; honor `stoppingToken` at every await; non-cancellable commit phases use `CancellationToken.None` explicitly.
- Queue consumers: ack after commit, idempotent handlers, bounded retry then dead-letter. Work that must survive restarts goes through an outbox/durable queue, not an in-memory channel.

## Serialization

- One shared `JsonSerializerOptions` instance; `new JsonSerializerOptions` outside composition is a bug. Enums as strings; `required` on mandatory contract fields.
- Contract changes are additive (expand/contract); property renames break stored payloads. Polymorphism via `[JsonPolymorphic]` allow-listed discriminators - never type names from input.
- Stream large payloads (`SerializeAsync`/`ReadFromJsonAsync`), don't buffer strings. Money and >2^53 ids as strings for JS consumers.

## Outbound HTTP

- Clients only via `IHttpClientFactory` typed clients, explicit `Timeout` (never the 100s default), caller's `CancellationToken` flowed into every send.
- Retries via resilience handlers: idempotent requests only (POST needs idempotency keys), 2-3 attempts, exponential backoff with jitter, honor `Retry-After`; circuit breaker with a decided fallback.
- Read error bodies before throwing; `ResponseHeadersRead` for large downloads; one client class per third-party API owning DTOs and error translation.

## Domain modeling

- Wrap primitives when they carry rules or get confused with neighbors (money, ids, email) - validated in the constructor, one place. Invariants enforced in constructors/methods, not settable properties; state transitions as methods.
- `record` for value objects and DTOs; classes for entities with identity. Exhaustive switch expressions without `default` on domain enums; `Enum.IsDefined` on client input.
- Flag: bool parameters, nullable-pair state machines (`ShippedAt != null` = shipped), public `List<T>` properties on entities.

## EF transactions and concurrency

- One use case = one `SaveChanges`; explicit transactions only for multi-save units. No ceremony transactions around a single `SaveChanges`.
- Read-modify-write on contended rows needs a rowversion concurrency token that round-trips through the client; `DbUpdateConcurrencyException` is a domain outcome with a decided policy (usually 409).
- Prefer atomic `ExecuteUpdateAsync` with guarded predicates and unique indexes over check-then-act. `EnableRetryOnFailure` + manual transactions require `CreateExecutionStrategy`, with no side effects inside the retried block.

## Collections and equality

- Return `IReadOnlyList<T>`/`IReadOnlyCollection<T>`; `IEnumerable<T>` only for genuinely lazy sequences; never null for empty. Entities expose read-only views with mutation methods.
- Override `Equals` and `GetHashCode` together via `IEquatable<T>` + `HashCode.Combine`, or use a record. Hash-relevant fields of dictionary/set keys are immutable.
- Build dictionaries before loops instead of `First(x => x.Id == id)` per iteration. String-keyed structures and LINQ set operators state their comparer explicitly.

## Pipeline order

- ExceptionHandler -> HTTPS -> StaticFiles -> Routing -> CORS -> Authentication -> Authorization -> endpoints. Authorization after authentication, CORS before auth, exception handler first - always.
- Endpoint-aware logic in filters/policies, not path-prefix checks in middleware. Scoped services as `InvokeAsync` parameters, never middleware constructor injection.
- `EnableBuffering` before reading request bodies; no response writes after `HasStarted`. Rate limiting on auth endpoints; liveness probes don't check dependencies.

## Culture

- Machine-boundary data (files, URLs, protocols, parsed logs): `InvariantCulture` on every Parse/ToString/Format. Human-facing text: an explicitly resolved culture. CA1305 at least as warning.
- Identifiers compare with `StringComparison.Ordinal`/`OrdinalIgnoreCase`; never `ToLower()` for comparison (Turkish-I bypasses). `IndexOf/StartsWith(string)` are culture-sensitive by default - specify.
- Exception messages and logs in invariant English; localize at the presentation edge from resource keys; ship ISO dates and raw numbers, format at the glass.

## Memory

- Long-lived state answers "what removes entries?" - bound every cache, dispose timers and CTS registrations, unsubscribe events symmetrically (`-=` in Dispose); no `static event` subscribers from shorter-lived objects.
- Lambdas stored long-term capture their enclosing scope - extract the field, capture the minimum. Every `TaskCompletionSource` has a guaranteed completion path.
- Diagnose with dotnet-counters + gcdump diffs before patching; leak = Gen2/LOH growth across collections, not rising working set. `GC.Collect()` in app code is rejected; leak fixes ship with before/after evidence.
