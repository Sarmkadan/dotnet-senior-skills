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
