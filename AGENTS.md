# .NET Senior Engineering Rules

Condensed rules for this codebase. Full versions with rationale and examples live in `skills/`.


## API

## Controller / endpoint: translation only

A controller method does exactly: bind + validate input shape, call one application-layer method, map result to an HTTP response. Budget: ~10 lines. Anything else has leaked.

Reject in controllers:
- `DbContext` or repository injection. The controller must not know persistence exists.
- Business conditionals (`if (order.Total > limit)`), loops over domain data, price/permission calculations.
- `SaveChanges`, transactions, `try/catch` that maps exceptions to status codes per-action - use exception-handling middleware / `IExceptionHandler` once, globally.
- Composing multiple service calls into a workflow. A workflow is an application-service method; the controller calls it by name.

```csharp
// non-compiling: illustrative
// WRONG: orchestration in controller
[HttpPost]
public async Task<IActionResult> Create(CreateOrderRequest req)
{
    var customer = await _customers.GetAsync(req.CustomerId);
    if (customer.IsBlocked) return BadRequest("blocked");
    var order = new Order { /* ... */ };
    _db.Orders.Add(order);
    await _db.SaveChangesAsync();
    await _email.SendAsync(customer.Email, "...");
    return Ok(order); // entity leaked, lazy-load serialization bomb included
}
// RIGHT
[HttpPost]
public async Task<ActionResult<OrderDto>> Create(CreateOrderRequest req, CancellationToken ct)
{
    var result = await _orderService.CreateAsync(req.ToCommand(), ct);
    return result is null ? Conflict() : CreatedAtAction(nameof(Get), new { id = result.Id }, result);
}
```

## Never return or accept entities at the HTTP boundary

- Returning an entity serializes navigation properties (cycles, lazy-load N+1 during serialization) and freezes your schema into your public contract - a column rename becomes a breaking API change.
- Accepting an entity as a request body is mass assignment: the client can set `Id`, `IsAdmin`, `CreatedAt`, any FK. Bind to a request DTO that contains only client-settable fields, and map explicitly.
- One DTO per direction and use case. Sharing a `UserDto` between create-request and detail-response forces nullable soup and accidental over-posting. Duplication of three properties is cheaper than a shared shape with divergent meanings.

## Application service: the workflow owner

Owns: use-case orchestration, transaction boundary (one `SaveChanges`/transaction per use case, at the end), authorization decisions on domain data, publishing events. Takes commands/queries or primitives, returns DTOs or results - never `IQueryable`, never tracked entities to the caller.

Reject in services:
- `HttpContext`, `IHttpContextAccessor` for anything but an abstracted `ICurrentUser`. The service layer must be callable from a message consumer or test without HTTP.
- Returning `IQueryable<T>`: it hands the caller an open connection and an unbounded query; the transaction/disposal semantics escape the layer. Compose queries inside; return materialized DTOs or a paged result.
- Formatting concerns: no status codes, no `ProblemDetails`, no localization of API messages.

## Repository / data layer

Only if it earns its keep. A repository wrapping `DbSet` one-to-one (`GetById`, `Add`, generic `IRepository<T>`) is ceremony - EF's `DbContext` already is a unit of work + repository. Write repositories when they encapsulate real query logic (specifications, complex read models, multi-source aggregation) or when the domain layer must not reference EF. Whichever you pick, be consistent: services calling `DbContext` directly in half the codebase and repositories in the other half is worse than either.

Data-layer rules regardless of pattern:
- No business decisions - a method named `GetActivePayableOrders` encodes policy in a filter; the policy belongs above, or must be named and owned as a shared specification.
- No `SaveChanges` sprinkled per-repository-call; the unit of work commits once per use case, else partial writes ship without transactions.

## Cross-cutting placement

- Input shape validation (required, range, format): FluentValidation/DataAnnotations at the boundary. Business invariants (credit limit, state transitions): domain/service layer. Do not duplicate business rules in boundary validators - they drift.
- Mapping: explicit methods or Mapster/AutoMapper with `ProjectTo` for queries; if a mapping needs services or conditionals, it is logic - write it as code, not configuration.
- Reference direction: API -> Application -> Domain <- Infrastructure. The domain project references nothing of yours. Any `using MyApp.Api.*` inside Application is an architecture bug regardless of whether it compiles.


## Async

## Sync-over-async

`.Result`, `.Wait()`, `.GetAwaiter().GetResult()` on an incomplete task: instant rejection in request paths. In classic ASP.NET, WPF, WinForms it deadlocks (continuation needs the captured context the blocking thread holds). In ASP.NET Core it does not deadlock but burns a thread-pool thread per call and collapses under load via pool starvation - the symptom is p99 latency spiking while CPU is idle.

```csharp
// non-compiling: illustrative
// WRONG
var user = _client.GetUserAsync(id).Result;
// RIGHT: make the caller async all the way up to the controller/handler
var user = await _client.GetUserAsync(id);
```

There is no safe wrapper. `Task.Run(...).Result` avoids the deadlock, costs two threads, and hides the design error. Fix the call chain. Acceptable exceptions: `Main` before async Main existed, and `IDisposable.Dispose` bridging (prefer `IAsyncDisposable`).

## ConfigureAwait

- Library code (no ASP.NET Core dependency, may be consumed from UI or legacy contexts): `ConfigureAwait(false)` on every await. One missing await re-introduces the deadlock risk for UI callers.
- ASP.NET Core application code: there is no SynchronizationContext; `ConfigureAwait(false)` is noise. Do not demand it in app-level reviews.

## async void

Only for event handlers. Anywhere else, exceptions escape to the SynchronizationContext or crash the process, the caller cannot await or observe completion, and tests pass while work is still running.

```csharp
// non-compiling: illustrative
// WRONG
public async void SaveAndNotify() { await _repo.SaveAsync(); }
// RIGHT
public async Task SaveAndNotifyAsync() { await _repo.SaveAsync(); }
```

Also flag `async` lambdas passed to `Action` parameters (e.g. `List.ForEach`, `Parallel.For`) - they compile to async void.

## Fire-and-forget

An unawaited task swallows its exceptions until (maybe) `TaskScheduler.UnobservedTaskException`. If work must outlive the request, do not spawn `_ = Task.Run(...)` in a handler - the DbContext and other scoped services it captured are disposed when the request ends. Enqueue to a hosted `BackgroundService` reading a `Channel<T>`, and resolve dependencies from a fresh `IServiceScope` inside the worker.

## ValueTask discipline

`ValueTask` is for hot paths that usually complete synchronously (cache hits). Rules: await it exactly once; never `.Result` it; never await it twice or store it and await later concurrently - backing `IValueTaskSource` objects are recycled and double-consumption reads someone else's state. If the consumer needs Task semantics (WhenAll, multiple awaits), call `.AsTask()` once or just return `Task`. Default to `Task`; `ValueTask` in a public API is a measured decision, not a habit.

## CancellationToken threading

- Every async public method on a service/repository takes `CancellationToken cancellationToken = default` as the last parameter, and passes it to every awaited call. A token accepted but not forwarded is a bug: cancellation silently stops at that frame.
- ASP.NET Core binds `HttpContext.RequestAborted` to a `CancellationToken` action parameter automatically - accept it in controllers and flow it down. Long queries and outbound HTTP calls that ignore it keep consuming the database after the client disconnected.
- Do not pass the request token into work that must complete (payment commit, outbox write). Split: cancellable read phase, non-cancellable commit phase, and say so with `CancellationToken.None` explicitly, not by omission.
- Check `ThrowIfCancellationRequested()` inside CPU-bound loops; awaits are the only implicit checkpoints.

## Miscellaneous review flags

- `Task.WhenAll` results: on multi-failure only the first exception propagates via await; if all failures matter, inspect `whenAllTask.Exception.InnerExceptions` or iterate tasks.
- Concurrent EF Core usage: `DbContext` is not thread-safe; `WhenAll` over two queries on one context throws `InvalidOperationException` intermittently. Sequential awaits or separate scopes.
- `async` method that awaits nothing on any path: remove the keyword, return the task directly - unless a `using`/`try` block wraps the return, where eliding await disposes before the task finishes.
- Timeouts: prefer `cts = CancellationTokenSource.CreateLinkedTokenSource(ct); cts.CancelAfter(timeout);` over `Task.Delay` races; on .NET 8+, `task.WaitAsync(timeout, ct)`.


## Background Work

## The loop that must not die

`ExecuteAsync` is called once. An unhandled exception ends the service silently for the rest of the process lifetime (pre-.NET 8) or tears down the whole host (.NET 8+ default `BackgroundServiceExceptionBehavior.StopHost`). Neither is what a polling loop wants - it wants to log and continue:

```csharp
// non-compiling: illustrative
// WRONG: first transient DB blip permanently stops processing (or kills the app)
protected override async Task ExecuteAsync(CancellationToken stoppingToken)
{
    while (!stoppingToken.IsCancellationRequested)
    {
        await ProcessBatchAsync(stoppingToken);
        await Task.Delay(_interval, stoppingToken);
    }
}
// RIGHT: failure of one iteration is logged, backed off, and survived
protected override async Task ExecuteAsync(CancellationToken stoppingToken)
{
    while (!stoppingToken.IsCancellationRequested)
    {
        try { await ProcessBatchAsync(stoppingToken); }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
        catch (Exception ex) { _logger.LogError(ex, "Batch failed, retrying after backoff"); }
        await Task.Delay(_interval, stoppingToken);
    }
}
```

This loop is one of the three sanctioned homes of `catch (Exception)`. The `OperationCanceledException` filter matters: cancellation during shutdown exits cleanly instead of logging a spurious error.

## Scoped services in a singleton world

Hosted services are singletons; `DbContext` is scoped. Injecting it is a captive dependency - one context instance living for the process lifetime, accumulating tracked entities and breaking on concurrent iterations. One scope per unit of work:

```csharp
using var scope = _scopeFactory.CreateScope();
var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
```

Per iteration or per message, not per service lifetime. A scope held for hours is the same bug with extra steps.

## Graceful shutdown

- Honor `stoppingToken` everywhere: every await in the loop takes it. A service ignoring it stalls shutdown until `HostOptions.ShutdownTimeout` (default 30s) expires and in-flight work is killed mid-write.
- Work that must not be killed mid-transaction: cancellable dequeue phase, non-cancellable commit phase (`CancellationToken.None`, explicitly) - and keep the commit short enough to finish inside the shutdown window.
- `StopAsync` overrides that await completion of in-flight work are correct; `StopAsync` doing new work is not.
- Kubernetes note: SIGTERM starts the shutdown clock; `terminationGracePeriodSeconds` must exceed `ShutdownTimeout` plus your longest commit, or the pod is SIGKILLed anyway.

## Timers are worse than loops

`System.Threading.Timer` firing an async callback is fire-and-forget: overlapping executions when work outlasts the interval, and exceptions vanish. The `while + Task.Delay` loop (or .NET 8+ `PeriodicTimer`) is strictly better - naturally non-overlapping, exception-visible, cancellation-aware:

```csharp
using var timer = new PeriodicTimer(_interval);
while (await timer.WaitForNextTickAsync(stoppingToken)) { await RunOnceAsync(stoppingToken); }
```

Review flag: any `new Timer(...)` in a hosted service, and any recurring schedule expressed in local time (see datetime skill - DST skips/doubles it).

## Queue consumers

- Ack/complete the message only after the work committed. Ack-then-process converts every crash into silent message loss.
- Every consumer assumes at-least-once delivery: handlers are idempotent (dedupe table keyed on message id, or naturally idempotent upserts). "The queue delivers exactly once" appearing in a design doc is a review rejection by itself.
- Poison messages: bounded retry with backoff, then dead-letter with the exception attached. An unbounded redelivery loop on a permanently failing message pins the consumer at 100% doing nothing.
- Concurrency limit is explicit (`MaxConcurrentCalls`, prefetch count) and sized against the downstream dependency, not defaulted.

## Scheduling work from requests

A request handler that needs work done after the response: do not `Task.Run` (captured scope dies with the request - see async skill). Minimum viable: a singleton `Channel<T>` written by the handler, drained by a hosted service. But if the work must survive a process restart, an in-memory channel is not a queue - use the outbox pattern (work row committed in the same transaction as the business change, relayed by a background service) or a durable queue. The review question is always "what happens if we deploy mid-flight?" - in-memory answers "the work is gone".


## Collections

## Return types: promise the least

- Public API returns: `IReadOnlyList<T>` / `IReadOnlyCollection<T>` for materialized data. Returning `List<T>` invites callers to mutate your internal state; returning `IEnumerable<T>` from a method that already has a list hides `Count` and invites re-enumeration paranoia (`.ToList()` calls sprinkled by nervous callers).
- Return `IEnumerable<T>` only when the sequence is genuinely lazy/streaming - and then the method name or docs say so, because every enumeration re-executes (the multiple-enumeration bug is in the performance skill; here the point is: do not create the ambiguity).
- Never return `null` for an empty collection: `Array.Empty<T>()` / `[]`. Every caller null-check on a collection return is a design apology.
- Parameters: accept the weakest thing you actually need - `IEnumerable<T>` if you only iterate once, `IReadOnlyCollection<T>` if you need `Count`. A parameter typed `List<T>` forces callers to copy.

## Exposed mutable collections

```csharp
// non-compiling: illustrative
// WRONG: any consumer can do order.Lines.Clear() - the invariant has a side door
public List<OrderLine> Lines { get; set; } = new();
// RIGHT: mutation goes through the method that enforces the rules
private readonly List<OrderLine> _lines = new();
public IReadOnlyCollection<OrderLine> Lines => _lines.AsReadOnly();
public void AddLine(OrderLine line) { /* rules */ _lines.Add(line); }
```

Note `AsReadOnly()` wraps (view of live list, cheap); `ToList()` in a getter copies per access - a `foreach` over a copying getter allocates once, but `order.Lines[i]` in a loop copies the entire list N times. Know which one you wrote.

## The Equals/GetHashCode contract

Equal objects must have equal hash codes, and the hash must not change while the object is in a hash-based collection. Violations do not throw - they make dictionary entries unfindable: `Add` succeeds, `TryGetValue` with an equal key returns false, `Remove` silently fails, counts drift.

- Override both or neither. `Equals` without `GetHashCode` compiles with a warning people suppress and breaks every `Distinct()`, `GroupBy()`, `HashSet`, and dictionary that touches the type.
- Implement via `IEquatable<T>` (avoids boxing in generic collections) and `HashCode.Combine(...)` - not hand-rolled XOR (collides symmetric values: `(a,b)` and `(b,a)` hash equal).
- Or don't implement at all: a `record` gets correct value equality generated. Hand-written equality on a type that could be a record is maintenance surface for zero gain - every added property must be added in three places or equality silently lies.
- **Mutable objects as dictionary/set keys**: the key's hash-relevant fields must never change post-insertion. A `HashSet<Item>` where `item.Name` (part of the hash) is later assigned = a corrupted set. Keys are immutable types - ids, strings, readonly record structs.

## Choosing the structure

- Lookup by key in any loop: `Dictionary`/`HashSet` built once, not `list.First(x => x.Id == id)` per iteration - that is O(n*m), the in-memory N+1 (performance skill), and it appears constantly in mapping code. `ToDictionary(x => x.Id)` before the loop.
- `ToLookup` for one-to-many grouping lookups; `GroupBy` when streaming groups once.
- `FrozenDictionary`/`FrozenSet` (.NET 8+) for build-once-read-forever singletons (config maps, routing tables) - faster reads than `Dictionary`, and the type documents the immutability.
- `ImmutableList` et al. are for shared-snapshot semantics (safe publication to concurrent readers), not a default - per-operation allocation makes them slower where nothing is shared.
- Struct enumeration: `List<T>` via `IEnumerable<T>` interface boxes its struct enumerator - iterate concrete types in hot loops (performance skill).

## String keys and comparers

Every hash structure keyed by strings states its comparer explicitly when case matters: `new Dictionary<string, T>(StringComparer.OrdinalIgnoreCase)`. Normalizing keys at insertion (`key.ToLowerInvariant()`) but not at lookup - or vice versa - is a bug the comparer makes impossible. Culture-sensitive comparers (`CurrentCulture`) in dictionaries: essentially never (see globalization skill); ordinal is the default for identifiers.

Same for LINQ set operators: `Distinct()`, `Except()`, `Contains()`, `GroupBy()` all take an `IEqualityComparer<T>` overload - flag any of them applied to strings or custom types where the intended equality is not the default one. `orders.Select(o => o.Email).Distinct()` deduplicates case-sensitively; if that is wrong, it is wrong silently.


## Concurrency

## First question: does this state need to be shared?

Most "how do I lock this" reviews end with removing the shared state: make the service scoped instead of singleton, pass values through the call chain, or use immutable snapshots. A singleton with mutable fields is guilty until proven thread-safe - and "proven" means every access site audited, not "it hasn't crashed yet". Races surface under production load as corrupted state, not as test failures.

## lock discipline

```csharp
// non-compiling: illustrative
// WRONG: check and act are separate; two threads both pass the check
if (!_cache.ContainsKey(key)) { _cache[key] = Create(key); }
// RIGHT: the whole read-modify-write under one lock (or use ConcurrentDictionary.GetOrAdd)
lock (_gate) { if (!_cache.TryGetValue(key, out var v)) { v = Create(key); _cache[key] = v; } }
```

- Lock object: `private readonly Lock _gate = new();` (.NET 9+) or `private readonly object _gate = new();`. Never `lock (this)`, `lock (typeof(X))`, or lock on a string - all reachable by other code, all deadlock bait.
- Hold locks for nanoseconds, not milliseconds: no I/O, no callbacks, no unknown virtual calls inside a lock. A lock around an HTTP call serializes your whole service.
- `await` inside `lock` does not compile - and the workaround people reach for (`Monitor.Enter` manually) is broken, because the continuation resumes on a different thread that does not own the monitor. Async mutual exclusion is `SemaphoreSlim(1, 1)`:

```csharp
await _semaphore.WaitAsync(ct);
try { await RefreshAsync(ct); }
finally { _semaphore.Release(); }
```

- Two locks acquired in different orders in different methods is the textbook deadlock. If you need two, define and document a global order; better, restructure to one.

## Interlocked and volatile

- Counters: `Interlocked.Increment(ref _count)`, not `_count++` (read-modify-write, loses updates) and not `lock` (overkill). Read with `Interlocked.Read`/`Volatile.Read` on the same field family.
- `volatile` is not a lock and not for counters - it orders reads/writes of a single field. If you are reasoning about fences to justify lock-free code outside a measured hot path, stop and take the lock; the review cost of clever memory-model code exceeds its benefit almost everywhere.
- Lazy one-time init: `Lazy<T>` or `LazyInitializer.EnsureInitialized`, not hand-rolled double-checked locking.

## Concurrent collections

- `ConcurrentDictionary`: `GetOrAdd`/`AddOrUpdate` are atomic per key, but the `valueFactory` may run multiple times concurrently (only one result wins). Factory with side effects (opens a connection, increments a counter): wrap the value in `Lazy<T>` - `GetOrAdd(key, k => new Lazy<T>(() => Create(k))).Value`.
- Iterating a concurrent collection gives a moving snapshot - `Count` then `foreach` can disagree. Do not build invariants across multiple calls; each call is atomic, the sequence is not.
- `List<T>` + `lock` beats `ConcurrentBag<T>` in almost every real case; `ConcurrentBag` is for same-thread-mostly producer-consumer and its unordered semantics surprise everyone.

## Producer-consumer: Channel<T>

Queue work between components with `System.Threading.Channels`, not `BlockingCollection` (blocks threads) or a hand-rolled `Queue` + lock + event:

```csharp
var channel = Channel.CreateBounded<WorkItem>(new BoundedChannelOptions(1000)
    { FullMode = BoundedChannelFullMode.Wait });
// producer: await channel.Writer.WriteAsync(item, ct);
// consumer: await foreach (var item in channel.Reader.ReadAllAsync(ct)) { ... }
```

Bounded, always - an unbounded channel is an unbounded memory leak when the consumer falls behind. `FullMode` is a deliberate backpressure decision: `Wait` (slow the producer), `DropOldest`/`DropWrite` (shed load) - pick per use case, in review.

## Parallelism

- CPU-bound batch over a collection: `Parallel.ForEachAsync(items, new ParallelOptions { MaxDegreeOfParallelism = n, CancellationToken = ct }, ...)`. Unbounded `Task.WhenAll(items.Select(DoAsync))` over 10k items fires 10k concurrent operations at your database or HTTP dependency - that is a self-inflicted DoS, not parallelism. Bound it (ForEachAsync, or `SemaphoreSlim` around the body).
- `Parallel.For`/`PLINQ` are for CPU-bound sync work only; feeding them async lambdas produces async void (exceptions escape, work outruns the loop).
- No parallelism inside a request handler for sub-100ms work - the thread coordination costs more than it saves, and it steals pool threads from other requests. Parallel work belongs in background jobs and batch processing.
- Shared `DbContext`, `HttpContext`, or any scoped service captured by parallel bodies: rejection. Each parallel unit resolves its own scope.


## Configuration

## Secrets: the hard rules (threshold: reject on sight)

- **No secret in `appsettings*.json`, code, or anything git-tracked.** Ever. A secret that touched a commit is compromised - rotate it; deleting the commit does not un-leak it.
- **Local development:** `dotnet user-secrets` (lives outside the repo) or environment variables. `appsettings.Development.json` is committed in most repos - it is NOT a secrets file.
- **Production:** a real secret store - Azure Key Vault / AWS Secrets Manager / Vault - loaded as a configuration provider, or platform-injected environment variables. Prefer the store: env vars appear in `docker inspect`, crash dumps, and diagnostic endpoints.
- **Connection strings are secrets** when they contain passwords. Prefer managed identity / IAM auth (`Authentication=Active Directory Default`) so the connection string stops being one.
- **Review flag:** any string named or shaped like `key`, `token`, `password`, `secret` assigned a literal. Also `DefaultAzureCredential` bypasses like raw account keys "temporarily".

### Before/After: hardcoded secrets

```csharp
// non-compiling: illustrative
// WRONG: secret in committed code
public class DatabaseService
{
    private readonly string _connectionString = "Server=prod;Database=app;User Id=admin;Password=SuperSecret123!";
    
    public DatabaseService()
    {
        // This connection string is now in git history forever
    }
}

// RIGHT: use configuration with proper secret storage
public sealed class DatabaseOptions
{
    public const string Section = "Database";
    public string ConnectionString { get; init; } = string.Empty;
}

// In Program.cs:
builder.Services.Configure<DatabaseOptions>(builder.Configuration.GetSection(DatabaseOptions.Section));
```

Threshold: any literal string containing `password=`, `secret=`, `token=`, or similar credential patterns in source control is a rejection.

---

## Options pattern, done properly (threshold: reject if IConfiguration injected outside composition root)

Inject `IOptions<T>` (or a snapshot), never `IConfiguration`, into services. `IConfiguration` in a constructor means stringly-typed access (`config["Smtp:Port"]`) scattered anywhere, untypeable, untestable, unvalidatable.

### Before/After: IConfiguration vs IOptions<T>

```csharp
// non-compiling: illustrative
// WRONG: stringly-typed configuration scattered throughout codebase
public class EmailService
{
    private readonly IConfiguration _config;
    
    public EmailService(IConfiguration config)
    {
        _config = config;
    }
    
    public void SendWelcomeEmail(string userId)
    {
        var host = _config["Smtp:Host"]; // What if key is missing? Returns null
        var port = _config.GetValue<int>("Smtp:Port"); // Silent 0 on missing key
        var apiKey = _config.GetValue<string>("Email:ApiKey"); // Where is this defined?
        
        // This pattern spreads like mold - no compile-time safety, no validation
    }
}

// RIGHT: strongly-typed options with validation
public sealed class SmtpOptions
{
    public const string Section = "Smtp";
    
    [Required]
    public required string Host { get; init; }
    
    [Range(1, 65535)]
    public int Port { get; init; } = 587;
    
    [Required]
    public required string ApiKey { get; init; }
}

// Composition root (Program.cs)
services.AddOptions<SmtpOptions>()
    .BindConfiguration(SmtpOptions.Section)
    .ValidateDataAnnotations() // Validates [Required], [Range], etc.
    .ValidateOnStart(); // Fails fast at deploy, not at 3 AM
```

Threshold: `IConfiguration` injected into any service class outside Program.cs is a rejection. Only the composition root should depend on `IConfiguration`.

---

## Lifetime semantics: choose deliberately (threshold: reject captive dependencies)

- **`IOptions<T>`**: singleton, frozen at first resolve. Default choice.
- **`IOptionsSnapshot<T>`**: scoped, re-reads per request - only when hot-reload of that setting is a real requirement.
- **`IOptionsMonitor<T>`**: for singletons needing current values or change callbacks. `OnChange` fires on the config provider's thread and can fire multiple times per file save - handlers must be idempotent and fast.

### Before/After: captive dependency in singleton

```csharp
// non-compiling: illustrative
// WRONG: Scoped service captured in singleton
public sealed class CacheService : BackgroundService
{
    private readonly IOptionsSnapshot<CacheOptions> _options;
    private readonly MemoryCache _cache = new();
    
    public CacheService(IOptionsSnapshot<CacheOptions> options)
    {
        _options = options; // Captures first scope's IOptionsSnapshot
    }
    
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            // Uses stale options from first scope
            var cacheDuration = _options.Value.Duration;
            await Task.Delay(TimeSpan.FromMinutes(cacheDuration), stoppingToken);
        }
    }
}

// RIGHT: Use IOptions<T> for singleton services
services.AddSingleton<CacheService>();
services.AddOptions<CacheOptions>()
    .BindConfiguration(CacheOptions.Section)
    .ValidateOnStart();

public sealed class CacheService : BackgroundService
{
    private readonly IOptions<CacheOptions> _options; // Singleton-safe
    private readonly MemoryCache _cache = new();
    
    public CacheService(IOptions<CacheOptions> options)
    {
        _options = options;
    }
    
    // ...
}
```

Threshold: `IOptionsSnapshot<T>` injected into a singleton service is a rejection - it creates a captive dependency.

---

## Validation at startup (threshold: reject if missing)

`ValidateOnStart()` is the point: a typo'd section name otherwise yields default-valued options that fail at 3 a.m. on first use instead of at deploy. Every options class gets it.

### Before/After: missing validation

```csharp
// non-compiling: illustrative
// WRONG: No validation - typos go unnoticed until production
services.AddOptions<SmtpOptions>()
    .BindConfiguration(SmtpOptions.Section); // Missing ValidateOnStart()

// RIGHT: Validate at startup
services.AddOptions<SmtpOptions>()
    .BindConfiguration(SmtpOptions.Section)
    .ValidateDataAnnotations()
    .ValidateOnStart(); // Fails fast: "Section 'Smtp' not found"
```

Threshold: Any `IOptions<T>` registration without `.ValidateOnStart()` is a rejection.

---

## Layering and environments (threshold: reject custom override mechanisms)

Provider order (later wins): appsettings.json -> appsettings.{Environment}.json -> user secrets (Dev) -> environment variables -> command line.

### Before/After: environment variable overrides

```bash
# WRONG: Custom override mechanism reinvented
# Instead of using standard env var: SMTP__PORT=2525
services.Configure<SmtpOptions>(options => 
    options.Port = int.Parse(Environment.GetEnvironmentVariable("SMTP_PORT_OVERRIDE") ?? "587"));

# RIGHT: Use standard double-underscore notation
# SMTP__PORT=2525 in environment automatically overrides appsettings.json
```

Consequences:
- Environment variables override JSON: `Smtp__Port=2525` (double underscore = section separator) beats the file. This is the deploy-time override mechanism; do not invent a custom one.
- `appsettings.Production.json` should contain only structural differences (log levels, feature toggles), not secrets and not full duplication of the base file - duplicated keys drift.
- Do not branch on environment name in code (`if (env.IsProduction())`) for behavior that is really a config value; add the config value. Environment checks are for infrastructure wiring (developer exception page, Swagger) only.

Threshold: Any custom configuration override mechanism (hardcoded environment variable names, custom parsing) is a rejection.

---

## Redaction in logging (ties into logging skill)

Never log configuration values, especially secrets. Use structured logging with redaction or exclude sensitive fields entirely.

### Before/After: logging sensitive configuration

```csharp
// non-compiling: illustrative
// WRONG: Logging configuration including secrets
var connectionString = builder.Configuration.GetConnectionString("Default");
_logger.LogInformation("Connecting to {ConnectionString}", connectionString); // Secret in logs!

// RIGHT: Never log connection strings or sensitive values
_logger.LogInformation("Connecting to database"); // No sensitive data
```

Threshold: Any log statement that includes configuration values containing `password`, `secret`, `key`, or `token` is a rejection.

---

## Review checklist

- **Secrets in git:** Any `.git-tracked` file containing secrets, or secrets committed to git history (even if later removed) is a rejection.
- **IConfiguration injected outside Program.cs:** Refactor to strongly-typed options.
- **Missing validation:** Any `IOptions<T>` registration without `.ValidateOnStart()` is a rejection.
- **Stringly-typed access:** `config["X"]` or `config.GetValue<string>("X")` in service constructors is a rejection.
- **Captive dependencies:** `IOptionsSnapshot<T>` injected into singleton services is a rejection.
- **Custom override mechanisms:** Reinventing environment variable parsing instead of using standard double-underscore notation is a rejection.
- **Logging sensitive values:** Any log statement that includes configuration values with `password`, `secret`, `key`, or `token` patterns is a rejection.
- **Connection strings with passwords:** Prefer managed identity / IAM auth to eliminate password from connection strings.
- **Production secrets in appsettings.Production.json:** All secrets must come from secret stores or environment variables, never committed files.
- **Feature flags as bools:** A bool in options is fine until it needs per-user targeting or runtime toggling - then a feature-management library, not a hand-rolled cache.

## Date/Time

## DateTimeOffset by default

`DateTime` carries a `Kind` flag that nothing enforces: a `Kind.Unspecified` value round-tripped through JSON, a database, or `ToLocalTime()` silently reinterprets the same ticks as a different instant. `DateTimeOffset` carries the offset in the value - comparisons and serialization are unambiguous.

```csharp
// non-compiling: illustrative
// WRONG: is this UTC? Local? Depends on who wrote it and which driver read it back.
public DateTime CreatedAt { get; set; }
// RIGHT
public DateTimeOffset CreatedAt { get; set; }
```

Decision table:
- **Instants** (created-at, expires-at, audit, logs, tokens): `DateTimeOffset`, stored as UTC. This is 90% of fields.
- **Calendar dates** (birthday, invoice date, holiday): `DateOnly`. A birthday has no timezone; storing it as midnight `DateTime` shifts it a day for half the planet.
- **Wall-clock times** (store opening hours): `TimeOnly` plus a timezone id stored separately.
- **Future local events** (a meeting at "10:00 Sofia time" next March): store local time + IANA timezone id, convert at read time. Pre-converting to UTC bakes in today's offset rules; a DST law change makes the stored instant wrong.

Review flag: `DateTime.Now` anywhere in server code. Server-local time depends on the box's timezone; two instances in different regions disagree. `DateTime.UtcNow` is acceptable in legacy code; new code uses `DateTimeOffset.UtcNow` - via `TimeProvider` (below).

## TimeProvider: the clock is a dependency

Any logic that branches on "now" (expiry, grace periods, business-day rules) is untestable when it calls the static clock. .NET 8+ ships `TimeProvider`; inject it, register `TimeProvider.System`, and use `FakeTimeProvider` (Microsoft.Extensions.TimeProvider.Testing) in tests.

```csharp
// non-compiling: illustrative
// WRONG: the test for "expires after 30 days" needs Thread.Sleep or a real month
if (DateTimeOffset.UtcNow > order.CreatedAt.AddDays(30)) { ... }
// RIGHT
public OrderService(TimeProvider clock) => _clock = clock;
if (_clock.GetUtcNow() > order.CreatedAt.AddDays(30)) { ... }
```

Multiple `UtcNow` reads inside one operation is a subtler bug: the value changes between reads, so "created" and "modified" timestamps of the same write differ. Read once at the top, pass the value down.

## Timezone conversion

- Convert at the presentation edge only. Storage, domain logic, and comparisons operate in UTC; the user's timezone applies exactly once, on display or on parsing user input.
- Use IANA ids (`Europe/Sofia`) - `TimeZoneInfo.FindSystemTimeZoneById` accepts them cross-platform since .NET 8. Windows ids (`FYRO Macedonia Standard Time`) in config are a portability bug.
- Never do arithmetic on local times: `localTime.AddHours(24)` across a DST transition is not "same time tomorrow". Convert to UTC, add, convert back - or use the date component and reattach the wall-clock time.
- `TimeZoneInfo.ConvertTime` on an ambiguous/invalid local time (the DST fold and gap) picks an answer silently. Code parsing user-supplied local times around 2-3 a.m. must decide policy explicitly (`IsAmbiguousTime`/`IsInvalidTime`).

## Durations and scheduling

- Elapsed time measurement: `Stopwatch` (or `TimeProvider.GetTimestamp()`/`GetElapsedTime`), never subtracting two `DateTime.Now` reads - the wall clock jumps on NTP sync, producing negative or hour-long "durations".
- `TimeSpan` for durations in APIs and options, not `int timeoutSeconds` - `TimeSpan.FromSeconds(30)` reads unambiguously, and misread units (ms vs s) are a classic 1000x incident.
- Recurring jobs defined as "daily at 02:30" in a DST-observing zone either skip or double-fire once a year. Schedule in UTC, or use a scheduler (Quartz, Hangfire) that has an explicit DST policy - not a hand-rolled `Task.Delay` loop computing the next local occurrence.

## Persistence and serialization flags

- SQL Server: `datetimeoffset` column for `DateTimeOffset`, `datetime2` never plain `datetime` (1753 floor, 3ms precision). PostgreSQL + Npgsql: `timestamp with time zone` stores UTC and Npgsql 6+ throws on non-UTC `DateTime` values - the exception is telling you a `Kind` bug exists upstream; fix the source, do not `SpecifyKind` at the call site.
- JSON: `System.Text.Json` emits ISO 8601. A client sending `"2026-07-17T10:00:00"` (no offset) deserializes into `Kind.Unspecified` - reject offset-less timestamps at the API contract level for instant fields.
- Unix epoch interop (`ToUnixTimeSeconds`) is always UTC by definition; a conversion helper that touches `TimeZoneInfo` on the way to epoch seconds is wrong.


## Dependency

## The one rule that causes 90% of DI bugs

A service must not depend on anything with a SHORTER lifetime. Singleton -> Scoped is the captive dependency: the singleton captures the first scope's instance forever.

```csharp
// non-compiling: illustrative
// WRONG: singleton captures a scoped DbContext
services.AddSingleton<ICacheWarmer, CacheWarmer>(); // ctor takes AppDbContext
```

Symptoms in production: `ObjectDisposedException: Cannot access a disposed context`, cross-request data bleed, "second request returns stale data". The default container validates this only when `ValidateScopes` is on - which is Development-only by default. Turn it on everywhere; the check is cheap:

```csharp
builder.Host.UseDefaultServiceProvider(o => { o.ValidateScopes = true; o.ValidateOnBuild = true; });
```

`ValidateOnBuild` also catches missing registrations at startup instead of first-request.

## Consuming scoped services from singletons (the right way)

Background services and singletons that need scoped services create a scope per unit of work:

```csharp
public class OutboxProcessor(IServiceScopeFactory scopeFactory) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            await using var scope = scopeFactory.CreateAsyncScope();
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            // one batch = one scope = one DbContext
        }
    }
}
```

One scope per iteration/batch, not one for the service lifetime (that recreates the captive bug manually) and not one per row (context churn).

## Choosing lifetimes

- **Scoped**: anything stateful per request - `DbContext`, unit of work, current-user accessors, most application services by default.
- **Singleton**: stateless and thread-safe - options, clients designed for it (`HttpClient` via factory handlers, most SDK clients like blob/queue clients), caches, pure policy objects. "Stateless" must be verified: a private `List<T>` field written in a method makes a singleton a race condition.
- **Transient**: cheap, stateless, and needed with fresh state per injection. Beware: transient `IDisposable` resolved from the ROOT provider is tracked until app shutdown - a slow leak. Transients belong in scopes.

When unsure between scoped and transient, pick scoped; when unsure between scoped and singleton, pick scoped. Promotion to singleton is an optimization done with proof of thread safety.

## IServiceProvider abuse

Injecting `IServiceProvider` and calling `GetService` inside business code is the service-locator anti-pattern: dependencies become invisible to callers and tests, and `ValidateOnBuild` cannot see them. Legitimate uses only: scope factories in singletons (above), factories resolving by runtime key, framework extension points. On .NET 8+, keyed services (`[FromKeyedServices("sms")] INotifier notifier`) remove most factory cases.

Related smells:
- Resolving services inside a constructor via provider then storing them - just inject them.
- `IHttpContextAccessor` deep in domain logic - wrap in an `ICurrentUser` abstraction registered scoped.
- Constructor doing real work (I/O, opening connections): constructors run at resolution time, sometimes at startup in surprising order. Constructors assign fields; work happens in methods.

## HttpClient registration

Never `new HttpClient()` per request (socket exhaustion) and never one static forever (DNS changes ignored). Use the factory:

```csharp
services.AddHttpClient<IGitHubApi, GitHubApi>(c => c.BaseAddress = new Uri("https://api.github.com"))
    .AddStandardResilienceHandler(); // Microsoft.Extensions.Http.Resilience
```

Typed clients are transient - do not inject a typed client into a singleton (captive again; inject `IHttpClientFactory` there instead).

## Registration hygiene

- Multiple registrations of the same interface: last one wins for single injection, all resolve for `IEnumerable<T>`. `TryAddScoped` in library/extension methods so consumers can override.
- Disposal: the container disposes what it CREATES. Instances you register (`AddSingleton(new Thing())`) are yours to dispose.
- Assembly-scanning auto-registration hides lifetime decisions; if you use it, pin non-default lifetimes explicitly and audit them in review - a scanner that registers a stateful class as singleton fails silently.


## Disposal

## The ownership rule

Whoever creates a disposable disposes it; whoever receives one does not. Every review question about disposal reduces to "who owns this instance?"

- Created in a method: `using` / `await using`, no exceptions.
- Created in a constructor and stored in a field: the class owns it, so the class implements `IDisposable` and disposes the field.
- Injected via DI: the container owns it. Disposing an injected `DbContext` or typed `HttpClient` breaks the next consumer of the same scoped instance. A class whose only disposables are injected does not implement `IDisposable` at all.

```csharp
// non-compiling: illustrative
// WRONG: disposing what DI owns; second service in the scope gets a disposed context
public sealed class OrderService : IDisposable
{
    private readonly AppDbContext _db;
    public OrderService(AppDbContext db) => _db = db;
    public void Dispose() => _db.Dispose();
}
// RIGHT: no IDisposable; the scope disposes the context
public sealed class OrderService
{
    private readonly AppDbContext _db;
    public OrderService(AppDbContext db) => _db = db;
}
```

## What must never be wrapped in using

- `HttpClient` from `IHttpClientFactory`: disposal is a no-op on the handler you care about, but `using` documents a false ownership. Sockets are managed by the factory's handler pool; `new HttpClient()` per call plus `using` is the classic socket-exhaustion bug (TIME_WAIT pileup under load).
- `CancellationTokenSource` still referenced by registered callbacks or linked sources elsewhere - dispose it, but only after nothing can use it; a fired timer callback touching a disposed CTS throws `ObjectDisposedException` intermittently.
- Streams passed into a serializer/reader with `leaveOpen` semantics: check the flag. `new StreamReader(stream)` disposes the underlying stream by default; when the caller still needs it, pass `leaveOpen: true`.

## IAsyncDisposable

Anything holding resources whose cleanup does I/O (DbContext, transactions, `System.Threading.Timer` with in-flight callbacks, streams over network) prefers `IAsyncDisposable`:

```csharp
await using var transaction = await _db.Database.BeginTransactionAsync(ct);
```

Rules:
- A type implementing `IAsyncDisposable` should also implement `IDisposable` (sync fallback) unless synchronous cleanup is impossible - non-DI callers and containers checking only one interface both exist.
- `Dispose()` calling `.GetAwaiter().GetResult()` on `DisposeAsync()` is sync-over-async in disguise; implement real sync cleanup or document that sync dispose is unsupported.
- `await using` on a type that only has `IDisposable` does not compile - do not "fix" it by fake-async wrappers.

## Implementing IDisposable

For a sealed class holding only managed disposables - the 95% case - the full pattern is overkill:

```csharp
public sealed class MeterRegistry : IDisposable
{
    private readonly Meter _meter = new("app");
    private bool _disposed;
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _meter.Dispose();
    }
}
```

- `Dispose` must be idempotent and never throw.
- The full `Dispose(bool disposing)` + finalizer pattern is only for classes directly owning unmanaged handles - and those should be `SafeHandle` instead, which eliminates the finalizer entirely. A finalizer on a class holding only managed fields is a rejection: it costs a GC generation for every instance and its "cleanup" touches fields that may already be finalized.
- Fields set to null in Dispose "to help the GC": noise, remove.

## Review flags

- Disposable created and returned from a method: the method name must convey transfer (`Create`, `Open`), and the caller must `using` it. A factory whose callers forget disposal shows up as connection-pool exhaustion at load, not in tests.
- Disposable stored in a static or singleton but recreated per operation - the previous instance leaks. `Timer`, `FileSystemWatcher`, event subscriptions: recreate implies dispose-old-first.
- `using var` scoping: `using var stream = ...` at the top of a long method holds the file handle for the whole method. Tighten with a block when the resource is only needed briefly.
- Iterator methods (`yield return`) and async methods: `using` inside them disposes only when enumeration/awaiting completes - an abandoned, half-enumerated iterator defers disposal to GC time. For handles that must close deterministically, materialize instead of yielding.


## Domain

## Primitive obsession: the threshold

A raw primitive is fine until it acquires rules or gets confused with its neighbors. The triggers for wrapping:
- Two same-typed parameters that must not be swapped: `Transfer(Guid fromAccountId, Guid toAccountId)` compiles happily with the arguments reversed. `AccountId` as a wrapped type turns the swap into a compile error.
- A validation rule enforced in more than one place: if `email` is regex-checked in the controller, the service, and the importer, the string should have been an `Email` type validating once, in its constructor.
- Money as `decimal`: adding EUR to USD compiles. `Money(decimal Amount, Currency Currency)` with an addition operator that throws on currency mismatch does not.

```csharp
// non-compiling: illustrative
// WRONG: every consumer re-validates or trusts blindly
public void Register(string email) { ... }
// RIGHT: an Email that exists is valid; the rule lives in one place
public readonly record struct Email
{
    public string Value { get; }
    public Email(string value)
    {
        if (!MailAddress.TryCreate(value, out _))
            throw new ArgumentException($"Invalid email: '{value}'", nameof(value));
        Value = value.Trim().ToLowerInvariant();
    }
    public override string ToString() => Value;
}
```

Do not wrap everything: a `PageNumber` type over an `int` used in one method is ceremony. The threshold is rules or confusability, not typing zeal. For EF mapping, value objects bind via `HasConversion`/`ComplexProperty` - "the ORM makes it hard" stopped being true years ago.

## Invariants live in constructors, not validators

An object that can exist in an invalid state forces every consumer to re-check it. Constructors (or factory methods, when creation can fail as a domain outcome) reject invalid states; from then on the type is proof.

- Public parameterless constructor + settable properties on a domain entity means the invariant is enforced nowhere. EF needs a private parameterless constructor at most; it does not need public setters (it sets backing fields).
- State transitions as methods, not property writes: `order.Ship(trackingNumber)` can enforce "only paid orders ship"; `order.Status = Shipped` cannot. A `Status` setter that any layer can write is where impossible states come from.
- Collections: expose `IReadOnlyCollection<OrderLine>` over a private list, mutate via `AddLine(...)` which enforces the rules. A public `List<T>` property is an invariant with a side door.

## Records: value semantics, not a class shorthand

- `record` for value objects and DTOs: equality by content is the point. `with` expressions give non-destructive mutation.
- Entities (things with identity and a lifecycle) are classes: two `Order` instances with the same data are not the same order, and record equality over a changing object is a trap - a record used as a dictionary key and then mutated via `with`-free property init misdirection is a lost key.
- Records with mutable properties (`set` instead of `init`) discard the guarantees while keeping the syntax - review flag.
- `readonly record struct` for small (< ~24 bytes) high-volume value objects (ids, quantities); reference records otherwise. Watch default-struct bypass: `default(Email)` skips your constructor - guard `Value` access or accept that empty means invalid downstream.

## Enums vs polymorphism

An enum plus one `switch` is fine - use exhaustive switch expressions (no `default` arm on domain enums, so a new member breaks compilation at every decision point instead of falling through silently). An enum plus the same `switch` in three places is dispatch you are hand-rolling: move the behavior onto the type (polymorphism or a strategy map). See the SOLID skill: name the cost, not the pattern.

Also: never persist enums by their numeric value into external contracts (see serialization skill), and `Enum.IsDefined` incoming values from clients - `(OrderStatus)42` casts without error.

## Anemic model: the honest assessment

All-getters-setters entities plus services that implement every rule is a valid architecture choice at CRUD complexity - do not flag it there. It becomes a defect at the point where the same business rule appears in two services, or where "what states can an Order be in" cannot be answered from the Order type. That is the review moment to push logic into the model - retrofit the specific rule being duplicated, not a wholesale DDD rewrite.

## Modeling review flags

- `bool` parameters changing method behavior (`Process(order, true)`) - unreadable at the call site; two methods or an options type.
- Nullable property pairs encoding a hidden state machine (`ShippedAt != null` means shipped): the state enum exists, write it down.
- Half the properties null in each state: two types being forced into one (see discriminated hierarchy in serialization skill).
- `DateTime`/`string` doing a domain type's job across a public API boundary: ids as `string` accept anything; typed ids accept ids.


## EF Core

## Classify every migration before merging

1. **Additive online** - new nullable column, new table, new index (if built concurrently). Safe to deploy in any order.
2. **Additive blocking** - new NOT NULL column without default on a large table, new index without `CONCURRENTLY` (Postgres) / `ONLINE = ON` (SQL Server). Locks the table for the duration.
3. **Destructive** - drop column/table, narrow a type, add a constraint existing rows violate, rename. Requires the expand/contract pattern below.

Grep the generated migration for `DropColumn`, `DropTable`, `AlterColumn`, `RenameColumn`, `AddColumn` with `nullable: false`. Any hit means the migration cannot be reviewed by skimming the model diff - read the SQL via `dotnet ef migrations script`.

## Renames are drops in disguise

EF cannot always tell a rename from drop+add. Verify the migration contains `RenameColumn`, not this:

```csharp
// non-compiling: illustrative
// WRONG: silently destroys data
migrationBuilder.DropColumn(name: "Surname", table: "Users");
migrationBuilder.AddColumn<string>(name: "LastName", table: "Users");
```

If the scaffolder produced drop+add, hand-edit it to `RenameColumn`. Test by applying to a database with data, not an empty one.

## Zero-downtime column changes (expand/contract)

Old app code and new schema coexist during a rolling deploy. Never ship a migration the *previous* app version cannot run against.

Adding a required column:

```csharp
// Release 1: add nullable, app writes it
migrationBuilder.AddColumn<string>("Region", "Orders", nullable: true);
// Release 2: backfill out-of-band, then enforce
migrationBuilder.Sql("UPDATE Orders SET Region = 'EU' WHERE Region IS NULL");
migrationBuilder.AlterColumn<string>("Region", "Orders", nullable: false);
```

Dropping a column: release 1 removes every read and write of the property but keeps it mapped, so old and new app versions both run against the existing column; release 2 removes the property from the model and ships the `DropColumn` migration. A one-release drop breaks the still-running old instances.

## NOT NULL with defaultValue on big tables

```csharp
migrationBuilder.AddColumn<bool>("IsActive", "Users", nullable: false, defaultValue: true);
```

On SQL Server 2012+/Postgres 11+ this is metadata-only. On older engines it rewrites the table under an exclusive lock. Know your target before approving.

## The shadow-property trap

An FK without a navigation-configured principal or a misspelled property gets a shadow column (`CustomerId1`). Symptoms: a duplicate-looking column in the migration, silently null FKs at runtime. When a migration adds a column you did not add to the model, stop - it is almost always a relationship EF inferred wrongly. Fix the model configuration; never merge the migration hoping it is harmless.

## Operational rules

- Never call `Database.Migrate()` from application startup in multi-instance deployments: concurrent migrators race, and a failed migration takes the app down. Run migrations as a separate deploy step (`dotnet ef database update` or an idempotent script with `--idempotent`).
- Generated `Down()` methods restore schema, not data. Treat rollback of destructive migrations as impossible; roll forward instead.
- Migrations are immutable once merged to main. Fix mistakes with a new migration, never by editing an applied one - the `__EFMigrationsHistory` hash will not match and other environments diverge.
- Squash only migrations that no environment has partially applied.
- Review raw SQL in migrations (`migrationBuilder.Sql`) for idempotency: it runs exactly once per database, but `--idempotent` scripts may replay surrounding context.

## N+1: lazy loading and loops over navigations

```csharp
// non-compiling: illustrative
// WRONG: 1 query for orders + N queries for customers
var orders = await db.Orders.ToListAsync();
foreach (var o in orders) Console.WriteLine(o.Customer.Name); // lazy-load per row
```

Fix with a projection, not an Include, when you only need a few fields:

```csharp
var rows = await db.Orders
    .Select(o => new { o.Id, CustomerName = o.Customer.Name })
    .ToListAsync(); // single query, single roundtrip
```

If lazy-loading proxies are enabled project-wide, treat every navigation access outside the query as a suspect. Prefer disabling lazy loading entirely; it converts silent N+1 into a visible exception.

## Cartesian explosion with multiple collection Includes

```csharp
// non-compiling: illustrative
// WRONG: rows = orders x items x payments; 100 orders with 50 items and 10 payments = 50,000 rows
var o = await db.Orders.Include(x => x.Items).Include(x => x.Payments).ToListAsync();
```

Two or more collection `Include`s on the same level multiply row counts. Use `AsSplitQuery()` (one query per collection, consistent only inside a transaction or with snapshot isolation) or split into separate targeted queries. One collection Include is fine; two is a review comment; three is a rejection.

## Projection over materialization

Materializing full entities to return a DTO is the most common over-fetch. `Select` into the DTO directly: EF translates it to a column list, skips change tracking, and avoids loading unmapped blobs.

```csharp
// non-compiling: illustrative
// WRONG
var users = await db.Users.Include(u => u.Profile).ToListAsync();
return users.Select(u => new UserDto(u.Id, u.Profile.AvatarUrl));
// RIGHT
return await db.Users.Select(u => new UserDto(u.Id, u.Profile.AvatarUrl)).ToListAsync();
```

## AsNoTracking

Every read-only query path (GET endpoints, reports, exports) must be `AsNoTracking()` or a projection (projections are untracked automatically). Tracking cost is per-entity snapshot allocation and identity-map lookups; on a 10k-row report it dominates. Do not set `NoTrackingWithIdentityResolution` by reflex - only when the same principal repeats across rows and reference identity matters. Conversely: if the code later mutates the entity and calls `SaveChanges`, `AsNoTracking` silently does nothing - that is a bug, not a perf win.

## Client-side evaluation

EF Core throws on non-translatable expressions everywhere except the final `Select` - and that exception is your friend. The dangerous cases are the ones that do NOT throw:

```csharp
// non-compiling: illustrative
// WRONG: ToList() before Where pulls the whole table
var active = db.Users.ToList().Where(u => IsActive(u));
// WRONG: AsEnumerable mid-query does the same, quietly
var page = db.Users.AsEnumerable().Skip(200).Take(20);
```

Any `ToList/AsEnumerable/ToArray` followed by more LINQ operators moves filtering into memory. Also flag calling instance methods or local functions inside `Where` - they force this pattern.

## Pagination and counting

- `Skip/Take` without `OrderBy` returns nondeterministic pages. Always order by a unique key (append `.ThenBy(x => x.Id)`).
- Offset pagination past ~10k rows scans; use keyset (`WHERE (CreatedAt, Id) > (@lastCreated, @lastId)`) for infinite scroll.
- `Count()` before fetching doubles roundtrips; if you need both, accept it explicitly or use a windowed `COUNT(*) OVER()` via raw SQL - do not call `.Count()` on a materialized list you fetched only for counting.

## Checklist for any reviewed query

- Filter (`Where`) and page (`Take`) in SQL, not memory.
- Read-only: `AsNoTracking` or projection.
- At most one collection Include per level, else `AsSplitQuery`.
- No `Contains` over an unbounded in-memory list (parameter limit blowups; batch or use temp table/`OPENJSON`).
- No queries inside loops - rewrite as one query with `Where(x => ids.Contains(x.Id))` or a join.

## SaveChanges is already a transaction

One `SaveChanges` call commits all its changes atomically. The explicit-transaction review flags run in both directions:

```csharp
// non-compiling: illustrative
// WRONG: ceremony around what SaveChanges already guarantees
using var tx = await _db.Database.BeginTransactionAsync(ct);
_db.Orders.Add(order);
await _db.SaveChangesAsync(ct);
await tx.CommitAsync(ct);
// WRONG the other way: two commits, crash between them leaves the order without its outbox event
await _db.SaveChangesAsync(ct);      // order
await _db.SaveChangesAsync(ct);      // outbox message - separate transaction!
// RIGHT: one use case, one SaveChanges
_db.Orders.Add(order);
_db.OutboxMessages.Add(evt);
await _db.SaveChangesAsync(ct);
```

An explicit transaction is warranted for exactly: multiple `SaveChanges` calls that must commit together (e.g. getting a database-generated id mid-flow), raw SQL mixed with tracked changes, or a lock-holding read-then-write sequence. The application service owns the boundary - repositories calling `SaveChanges` internally turn one use case into N independent commits (see api-layer skill).

## The lost update, and why you already have one

Read-modify-write without a concurrency token means last-writer-wins: two users load the same row, both save, one edit silently vanishes. No exception, no log - discovered weeks later as "the system lost my changes".

```csharp
public class Order
{
    [Timestamp] public byte[] RowVersion { get; set; } = null!;  // SQL Server rowversion
}
// PostgreSQL: modelBuilder.Entity<Order>().Property(o => o.Version).IsRowVersion(); // maps xmin
```

`SaveChanges` then throws `DbUpdateConcurrencyException` when the row changed underneath - and that exception is a domain outcome, not an error to log-and-rethrow. Policy per use case, decided in review: reject (409 to the client with fresh state - the default), retry the whole read-modify-write (only when the operation is a pure function of current state, like a counter), or field-level merge (rare, deliberate). Catch-and-ignore is choosing lost updates back, with extra steps.

Web round-trip: the token must travel to the client and come back with the edit (hidden field / DTO property), and the update applies it via `OriginalValue`. A token that is loaded fresh in the PUT handler compares the row against itself - always passes, protects nothing.

## Atomic alternatives beat read-modify-write

- Counters/balances: `ExecuteUpdateAsync(s => s.SetProperty(a => a.Balance, a => a.Balance - amount))` with a `WHERE Balance >= amount` guard in the predicate - atomic in the database, no token dance, no race. Check the affected-row count.
- Uniqueness: a unique index plus handling the violation, never `if (!await _db.Users.AnyAsync(u => u.Email == email))` then insert - two concurrent requests both pass the check (TOCTOU). The index is the invariant; the pre-check is at most a UX nicety.
- Queue-like table processing by competing consumers: `FOR UPDATE SKIP LOCKED` (raw SQL or provider support), not optimistic collisions on every poll.

## Execution strategies vs transactions

`EnableRetryOnFailure` retries the whole operation on transient failures - but a `BeginTransaction` block is not a retriable unit by itself. Combining them throws `InvalidOperationException` unless the transaction work is wrapped in the strategy:

```csharp
var strategy = _db.Database.CreateExecutionStrategy();
await strategy.ExecuteAsync(async () =>
{
    await using var tx = await _db.Database.BeginTransactionAsync(ct);
    // ... work, SaveChanges, possibly twice ...
    await tx.CommitAsync(ct);
});
```

The block must be safe to re-run from the top: no captured state mutated outside it, no non-idempotent side effects (HTTP calls, queue publishes) inside - a retry would repeat them. Side effects go after the commit, or through the outbox.

## Boundaries that do not fit one transaction

- Two databases, or database + queue/HTTP: no distributed transactions (`TransactionScope` across resources escalates to MSDTC or throws; cloud managed databases do not support it). The pattern is outbox + idempotent consumers - commit locally, relay asynchronously, tolerate at-least-once.
- Long "transactions" spanning user think-time: never hold a database transaction across user interaction. Optimistic tokens (above) are the mechanism for edit sessions.
- Isolation level bumps (`Serializable`) to fix a race: usually the wrong tool - deadlock rate rises with load. Prefer the atomic-UPDATE/unique-index/`SKIP LOCKED` designs above; escalate isolation only with the specific anomaly named in the PR description.


## Errors

## The dividing line

- **Throw** for the exceptional: broken invariants, unreachable states, infrastructure failure, programmer error. The caller cannot meaningfully continue.
- **Return a result** for expected domain outcomes the caller must branch on: validation failure, "insufficient funds", "already exists", not-found in a lookup that legitimately misses.

The test: if the immediate caller would catch the exception and convert it to control flow, it should have been a return value. Exceptions-as-control-flow costs a stack capture per throw (~microseconds each - ruinous in loops) and hides branches from the reader.

```csharp
// non-compiling: illustrative
// WRONG: expected outcome modeled as exception
try { await _orders.PlaceAsync(cmd); return Ok(); }
catch (InsufficientStockException e) { return Conflict(e.Message); }
// RIGHT: expected outcome in the signature
var result = await _orders.PlaceAsync(cmd);
return result.Match<IActionResult>(
    order => Ok(order),
    error => error.Code == "OutOfStock" ? Conflict(error) : BadRequest(error));
```

Pick one Result implementation for the codebase (ErrorOr, FluentResults, or a 30-line in-house `Result<T>`) and use it only at the application-service boundary. Result types in every private helper produce `.Bind(...)` soup C# has no syntax for; deep internals may throw and let the service method translate.

## Rules for throwing

- Guard clauses throw immediately: `ArgumentNullException.ThrowIfNull(x)`, `ArgumentOutOfRangeException.ThrowIfNegative(n)`. Fail at the mistake, not three layers deep.
- Define exception types per handling-decision, not per failure site. If `PaymentGatewayException` and `PaymentTimeoutException` are always caught by the same handler doing the same thing, one type with a property suffices.
- Include the identifiers in the message: `throw new InvalidOperationException($"Order {orderId} is in state {state}, cannot ship")`. "Operation is not valid" costs a production debugging hour.
- Rethrow with `throw;` never `throw ex;` (which resets the stack trace). Wrap only when adding context: `throw new OrderImportException($"row {i}", ex)` - always pass the inner exception.

## Catch rules

- Catch the most specific type that you can actually handle. "Handle" means: retry, fallback, compensate, or translate at a boundary. Log-and-rethrow at every layer is noise - one boundary logs.
- `catch (Exception)` is legal in exactly three places: top-level middleware/pipeline behavior (translate to 500 + log), message-consumer loop (nack/dead-letter, keep consuming), and background-service loop (log, delay, continue). Everywhere else, name the type.
- An empty catch block is a rejection, no discussion. Minimum viable swallow is `catch (SpecificException ex) { _logger.LogWarning(ex, "context, deliberately ignored because X"); }` - the "because X" is mandatory.

## Never swallow

- `OperationCanceledException` when cancellation was requested - let it propagate; the pipeline maps it to 499/aborted. Catching it and returning a fake success corrupts caller assumptions. (Do catch it to run cleanup, then rethrow.)
- Exceptions in `finally`/`Dispose` that mask the original in-flight exception - keep Dispose non-throwing.
- `OutOfMemoryException`, `StackOverflowException`, `ThreadAbortException`: not yours to handle.
- Failures during a commit/ack: if `SaveChanges` threw after a payment was captured, swallowing turns an incident into silent data divergence. Compensate or crash loudly.

## HTTP boundary translation

One global `IExceptionHandler` (or exception middleware) owns exception-to-ProblemDetails mapping. Controllers contain zero try/catch. Map: domain result errors -> 400/404/409 with error codes; `OperationCanceledException` -> client abort; everything else -> 500 with a correlation id and NO exception detail in the body (internals leak: stack frames, connection strings in EF messages). Return machine-readable error codes (`"error": "order_out_of_stock"`), not prose the frontend will string-match.


## Globalization

## The default is a landmine

`double.Parse`, `decimal.ToString`, `DateTime.Parse`, `string.Format`, and interpolation all default to `CultureInfo.CurrentCulture` - the culture of the thread, which in a server means "whatever the OS image or a stray configuration set". Code that works on the developer's en-US machine and corrupts data on a de-DE server:

```csharp
// non-compiling: illustrative
// WRONG: on a German-culture server, "1.5" parses as 15 (dot is a thousands separator)
var price = decimal.Parse(priceText);
// WRONG: emits "1,5" into a CSV/JSON/SQL string that expects "1.5"
var s = price.ToString();
// RIGHT: machine-to-machine data is invariant, always
var price = decimal.Parse(priceText, CultureInfo.InvariantCulture);
var s = price.ToString(CultureInfo.InvariantCulture);
```

The dividing rule: **data crossing a machine boundary** (files, protocols, URLs, database strings, config, logs meant for parsing) is `InvariantCulture`; **text rendered for a human eye** is the user's culture - explicitly resolved, not whatever the thread has. Any Parse/ToString/Format of numbers or dates with no `IFormatProvider` argument is a review question; enable CA1305 (specify IFormatProvider) as at least a warning to make the omissions visible.

Interpolated strings crossing machine boundaries: `FormattableString.Invariant($"page={page}&price={price}")` or `string.Create(CultureInfo.InvariantCulture, $"...")` - a bare `$"..."` building a URL formats the decimal with the thread culture.

## String comparison: say what you mean

Every comparison picks a `StringComparison`, and the unstated default differs by API - `==`/`Equals` are ordinal, but `string.Compare`, `CompareTo`, `IndexOf(string)`, `StartsWith(string)`, `EndsWith(string)` are **culture-sensitive** by default. That inconsistency is the bug generator: `list.Sort()` on strings and `s.StartsWith(prefix)` both behave differently per server culture.

- Identifiers, keys, headers, protocol tokens, file paths, anything a machine consumes: `StringComparison.Ordinal` / `OrdinalIgnoreCase`. This is 95% of server-side comparisons.
- Human-facing sorting/searching (a customer list ordered for display): `StringComparison.CurrentCulture` with the user's culture explicitly set - a deliberate, commented choice.
- `ToLower()`/`ToUpper()` for comparison purposes is always wrong twice: allocates, and uses current culture. `string.Equals(a, b, OrdinalIgnoreCase)` or an `OrdinalIgnoreCase` comparer on the collection (see collections skill).

The Turkish-I is the concrete failure: in tr-TR, `"INSERT".ToLower()` is `"ınsert"` (dotless ı), so `command.ToLower() == "insert"` fails, and security checks normalizing case with culture-sensitive lowering have produced real bypasses (`"ADMIN"` != `"admin"` checks defeated). Casing for comparison uses `OrdinalIgnoreCase` comparison, not pre-lowering; casing for storage normalization uses `ToLowerInvariant()`.

## Server culture discipline

- Do not set `Thread.CurrentThread.CurrentCulture` per request as an ambient side channel for formatting; it leaks across awaits into pooled threads' unrelated work only if set wrong (it flows with ExecutionContext - the real issue is that ambient state hides the dependency). Pass the resolved `CultureInfo` explicitly to the formatting seam, or use ASP.NET Core `RequestLocalization` middleware where the culture legitimately drives the response.
- `InvariantGlobalization` (`<InvariantGlobalization>true</InvariantGlobalization>`) for pure-API services with no human-facing formatting: smaller images, no ICU dependency, and every culture-sensitive call now behaves invariantly - which also converts hidden culture bugs into consistent behavior. Turning it on with existing `CurrentCulture` sorting is a behavior change; audit first.
- Docker note: default images may lack ICU (`Globalization.Invariant` mode silently on via the runtime image) - code assuming culture-aware behavior gets invariant instead, without an exception unless configured. Decide the mode explicitly in the csproj, not by base-image accident.

## Localization boundaries

- Exception messages, log templates, and internal errors: English, invariant, never localized - logs get grepped, not read by end users. User-visible text is translated at the presentation edge from resource keys; a domain layer throwing localized exception messages has mixed presentation into domain.
- Error codes over prose across the API boundary (exception skill) - the frontend localizes `order_out_of_stock`; it cannot localize a server-composed English sentence.
- Dates/numbers rendered client-side (JS `Intl`, mobile) beat server-side rendering into strings - ship ISO 8601 and raw numbers in the payload, format at the glass (see serialization skill).

## Client construction

`new HttpClient()` per operation exhausts sockets (each instance owns a handler and its connections; disposed connections sit in TIME_WAIT). A single static `HttpClient` fixes that but caches DNS forever - it keeps calling the old IP after a failover. `IHttpClientFactory` solves both; it is the only acceptable construction in application code:

```csharp
services.AddHttpClient<PaymentsClient>(c => 
{
    c.BaseAddress = new Uri(opts.BaseUrl);
    c.Timeout = TimeSpan.FromSeconds(10);
});
```

Typed clients over named clients (compile-checked, config in one place). Two reminders from the DI skill: typed clients are transient - injecting one into a singleton freezes a single handler past its rotation window (stale DNS returns); and do not `using` the injected client.

## Timeouts: the non-negotiable

The review question for every outbound call: "what happens when this dependency hangs?" The default 100-second `HttpClient.Timeout` means the answer is "requests pile up for 100 seconds, then the thread pool and connection pool are gone" - a slow dependency takes you down harder than a dead one.

- Every client gets an explicit `Timeout` sized to the dependency's p99 plus margin - seconds, not the default.
- Per-attempt vs overall: `HttpClient.Timeout` caps the whole operation including retries inside a `DelegatingHandler`; the per-attempt timeout is a resilience-pipeline policy. You need both, and per-attempt < overall / (retries + 1) or the retries never happen.
- Flow the caller's `CancellationToken` into every `SendAsync`/`GetAsync` - a timeout policy without the request token keeps calling dependencies for clients that already disconnected.

## Retries without a foot-gun

**Reject legacy Polly v7 syntax.** The old `Policy.Handle<T>().WaitAndRetryAsync` and manual `IAsyncPolicy` registrations produce verbose, error-prone code that bypasses .NET 8+ resilience infrastructure. Agents writing v7 patterns must be rejected:

```csharp
// BEFORE - REJECT: Legacy Polly v7 hand-rolled registration
services.AddTransient<IAsyncPolicy<HttpResponseMessage>>(sp =>
    Policy.Handle<HttpResponseException>()
        .WaitAndRetryAsync(3, retryAttempt => TimeSpan.FromSeconds(Math.Pow(2, retryAttempt)),
        onRetry: (outcome, delay, retryCount, context) =>
        {
            // Manual logging, manual jitter, manual context
            _logger.LogWarning("Retry {RetryCount} for {Request},", retryCount, context["request"]);
        }));

services.AddHttpClient<LegacyClient>()
    .AddPolicyHandlerFromRegistry(Registry); // Brittle, no DI integration
```

**Enforce Microsoft.Extensions.Http.Resilience v8.** Use the standardized resilience handler that integrates with `IHttpClientFactory`, respects DI, and applies sensible defaults:

```csharp
// AFTER - ACCEPT: .NET 8+ Microsoft.Extensions.Http.Resilience
services.AddHttpClient<CatalogClient>(c =>
{
    c.BaseAddress = new Uri("https://api.example.com");
    c.Timeout = TimeSpan.FromSeconds(15); // Overall timeout
})
.AddStandardResilienceHandler(options =>
{
    options.Retry = new HttpRetryStrategyOptions
    {
        MaxRetryAttempts = 3,
        BackoffType = DelayBackoffType.Exponential,
        UseJitter = true, // Critical: prevents retry storms
        MaxDelay = TimeSpan.FromSeconds(5),
        Delay = TimeSpan.FromSeconds(0.8), // Per-attempt timeout
        ShouldHandle = new PredicateBuilder<HttpResponseMessage>()
            .Handle<HttpRequestException>()
            .HandleResult(response => !response.IsSuccessStatusCode &&
                (response.StatusCode == System.Net.HttpStatusCode.RequestTimeout ||
                 response.StatusCode == System.Net.HttpStatusCode.TooManyRequests ||
                 response.StatusCode >= System.Net.HttpStatusCode.InternalServerError))
    };
    
    options.CircuitBreaker = new HttpCircuitBreakerStrategyOptions
    {
        BreakDuration = TimeSpan.FromSeconds(30),
        SamplingDuration = TimeSpan.FromSeconds(60),
        FailureRatio = 0.5, // 50% failure rate
        ShouldHandle = new PredicateBuilder<HttpResponseMessage>()
            .Handle<HttpRequestException>()
            .HandleResult(response => response.StatusCode >= System.Net.HttpStatusCode.InternalServerError)
    };
});
```

Rules that survive contact with production:
- **Retry only idempotent things.** GET/PUT/DELETE by spec; POST only when the API supports idempotency keys - and then send one. Retrying a non-idempotent POST on timeout is how customers get charged twice: the timeout does not mean the first attempt failed, it means you do not know.
- Retry counts: 2-3 with exponential backoff and jitter. Aggressive retries against a struggling dependency are a retry storm - you become the DDoS. **Jitter is not optional**; synchronized retry waves from N instances re-kill the recovering service.
- Retry on: 408 (Request Timeout), 429 (Too Many Requests - **honor `Retry-After` header**), 5xx, connection failures. Never on 4xx besides those - retrying a 400 three times just burns latency on a request that cannot succeed.
- **Circuit breaker on every dependency that can brown-out:** fail fast after the threshold instead of stacking doomed calls. Define the fallback behavior in review (cached data? degraded response? 503?) - a breaker without a decided fallback just moves where the exception is thrown.
- **Timeout ordering:** Per-attempt timeout < overall timeout / (max retries + 1). If the per-attempt timeout is too long, retries never occur; if too short, legitimate calls fail. Example: overall 15s timeout with 3 retries → per-attempt ≤ 3.75s (use 3s).

## Response handling

- `EnsureSuccessStatusCode()` throws `HttpRequestException` with no body - useless in logs. When the API returns error details, read them: check `IsSuccessStatusCode`, capture status + a truncated body into the exception/log, then throw something meaningful.
- `response.Content.ReadFromJsonAsync<T>(ct)`: streams and honors charset. `ReadAsStringAsync` + manual `Deserialize` buffers the payload twice.
- `HttpCompletionOption.ResponseHeadersRead` for large downloads - default buffers the entire body into memory before your first read. Pair with `await using` on the response stream.
- A `null` deserialized body from a 200 is a contract violation, not a value: throw, do not null-propagate a half-response into domain logic.

## Boundary hygiene

- Wrap each third-party API in one client class owning the DTOs, auth, and error translation. `HttpClient` calls and vendor DTOs scattered through application services means a vendor change is a whole-codebase change (see api-layer skill: same rule as any boundary).
- Outbound auth: tokens fetched and cached by a `DelegatingHandler`, not per-call, and never logged (query-string tokens leak via logs - auth belongs in headers).
- Every outbound call is in traces: `IHttpClientFactory` + OpenTelemetry propagates `traceparent` automatically; a client built outside the factory silently drops correlation.

## Input Validation

## Never trust input: validate at the boundary

Every piece of data entering the application must be validated at the API boundary before any processing. Validation is not optional; it is a security control. Place validation as close to the entry point as possible - controllers, minimal APIs, gRPC services, message consumers.

Reject in controllers/endpoints:
- Accepting entities directly as request bodies (mass assignment vulnerability)
- Using unvalidated route parameters, query strings, or headers in database queries
- Passing raw user input to raw SQL or dynamic LINQ
- Returning unbounded result sets to clients
- Allowing unbounded page sizes or offsets

```csharp
// non-compiling: illustrative
// WRONG: binding directly to entity enables mass assignment
[HttpPost]  
public async Task<IActionResult> Create(User user)  // user.Id, user.IsAdmin, user.CreatedAt are all settable!
{
    _db.Users.Add(user);
    await _db.SaveChangesAsync();
    return Ok(user);
}

// RIGHT: bind to request DTO with explicit validation
[HttpPost]
public async Task<ActionResult<UserDto>> Create(CreateUserRequest request, [FromServices] IValidator<CreateUserRequest> validator, CancellationToken ct)
{
    await validator.ValidateAndThrowAsync(request, ct);
    var user = request.ToEntity(); // explicit mapping, server-owned fields set here
    _db.Users.Add(user);
    await _db.SaveChangesAsync(ct);
    return CreatedAtAction(nameof(Get), new { id = user.Id }, user.ToDto());
}
```

## SQL injection: parameterize everything

EF Core LINQ queries are automatically parameterized and safe. The danger zone is raw SQL. Never concatenate user input into SQL strings.

Reject:
- `FromSqlRaw`/`ExecuteSqlRaw` with string interpolation or concatenation
- `FromSql`/`ExecuteSql` with `string.Format` or manual parameter building
- Dynamic SQL where identifiers come from user input

Accept:
- `FromSqlInterpolated` (converts interpolation to parameters)
- `FromSql` with parameter placeholders (`FromSql("SELECT * FROM Users WHERE Name = {0}", name)`)
- `FromSqlRaw`/`ExecuteSqlRaw` with anonymous object parameters

```csharp
// non-compiling: illustrative
// WRONG: string interpolation creates SQL injection
var users = db.Users.FromSqlRaw($"SELECT * FROM Users WHERE Name = '{name}'");

// WRONG: string.Format is just as dangerous
var users = db.Users.FromSqlRaw(string.Format("SELECT * FROM Users WHERE Name = '{0}'", name));

// WRONG: raw with concatenation
var users = db.Users.FromSqlRaw("SELECT * FROM Users WHERE Name = '" + name + "'");

// RIGHT: FromSqlInterpolated turns holes into parameters
var users = db.Users.FromSqlInterpolated($"SELECT * FROM Users WHERE Name = {name}");

// RIGHT: parameter object
var users = db.Users.FromSqlRaw("SELECT * FROM Users WHERE Name = {0}", name);

// RIGHT: anonymous object for multiple parameters
var users = db.Users.FromSqlRaw("SELECT * FROM Users WHERE Name = {0} AND Age > {1}", name, minAge);
```

Identifiers (table names, column names, ORDER BY direction) cannot be parameterized. Always allowlist them against a fixed set:

```csharp
private static readonly HashSet<string> AllowedSortColumns = new(StringComparer.OrdinalIgnoreCase)
{
    "Name", "Email", "CreatedAt", "Id"
};

[HttpGet]
public async Task<IActionResult> List([FromQuery] string sortBy = "Name")
{
    if (!AllowedSortColumns.Contains(sortBy))
        return BadRequest("Invalid sort column");
    
    var query = sortBy switch
    {
        "Name" => db.Users.OrderBy(u => u.Name),
        "Email" => db.Users.OrderBy(u => u.Email),
        _ => db.Users.OrderBy(u => u.Name)
    };
    return Ok(await query.ToListAsync());
}
```

## Pagination: always bound and capped

Never allow clients to request unbounded result sets. Every paginated endpoint must:
- Accept `pageSize` and `pageNumber` or `skip`/`take` parameters
- Validate these parameters with `[Range]` or equivalent
- Apply an absolute maximum page size (typically 100-500 items)
- Return a `PagedResult<T>` or similar wrapper with total count

Reject:
- Endpoints without pagination parameters that could return thousands of rows
- Parameters without validation
- Page sizes above the maximum (e.g., `?pageSize=1000000`)

```csharp
// non-compiling: illustrative
// WRONG: unbounded query
[HttpGet("users")]
public async Task<IActionResult> GetAllUsers()
{
    var users = await _db.Users.ToListAsync(); // N+1, memory explosion
    return Ok(users);
}

// WRONG: pagination without validation
[HttpGet("users")]
public async Task<IActionResult> GetUsers([FromQuery] int pageNumber = 1, [FromQuery] int pageSize = 10)
{
    var users = await _db.Users
        .OrderBy(u => u.Name)
        .Skip((pageNumber - 1) * pageSize)
        .Take(pageSize)
        .ToListAsync();
    return Ok(users);
}

// RIGHT: validated pagination with maximum
public record GetUsersRequest([property: Range(1, int.MaxValue)] int PageNumber = 1,
                           [property: Range(1, 500)] int PageSize = 50);

[HttpGet("users")]
public async Task<ActionResult<PagedResult<UserDto>>> GetUsers([FromQuery] GetUsersRequest request, CancellationToken ct)
{
    var query = _db.Users.OrderBy(u => u.Name);
    var total = await query.CountAsync(ct);
    var users = await query
        .Skip((request.PageNumber - 1) * request.PageSize)
        .Take(request.PageSize)
        .ProjectToDto()
        .ToListAsync(ct);
    
    return Ok(new PagedResult<UserDto>(users, total));
}
```

## Mass assignment: never bind entities directly

Binding a request body to an entity allows clients to set any property, including server-owned fields like `Id`, `CreatedAt`, `IsAdmin`, `Status`, or foreign keys. Always use request DTOs with explicit mapping.

Reject:
- `[FromBody] Entity` in controller parameters
- AutoMapper profiles that map request DTOs to entities with `ForAllMembers` or similar broad mappings
- Copying properties from request to entity without field-by-field validation

Accept:
- Request DTOs with only client-settable fields
- Explicit mapping methods (`ToEntity`, `ToCommand`, `ToDto`)
- Constructor initialization of server-owned fields

```csharp
// non-compiling: illustrative
// WRONG: mass assignment vulnerability
[HttpPost]
public async Task<IActionResult> UpdateUser([FromBody] User user)
{
    var existing = await _db.Users.FindAsync(user.Id);
    if (existing == null) return NotFound();
    
    // DANGER: client can set IsAdmin, CreatedAt, etc.
    _mapper.Map(user, existing);
    await _db.SaveChangesAsync();
    return NoContent();
}

// RIGHT: request DTO with explicit mapping
public record UpdateUserRequest(string Name, string Email, string? Phone);

[HttpPut("users/{id}")]
public async Task<IActionResult> UpdateUser(int id, [FromBody] UpdateUserRequest request, CancellationToken ct)
{
    var user = await _db.Users.FindAsync(new object?[] { id }, ct);
    if (user == null) return NotFound();
    
    // Explicit mapping - only client-settable fields
    user.Name = request.Name;
    user.Email = request.Email;
    user.Phone = request.Phone;
    
    await _db.SaveChangesAsync(ct);
    return NoContent();
}

// Alternative: constructor initialization for new entities
public record CreateUserRequest(string Name, string Email, string Password);

[HttpPost("users")]
public async Task<ActionResult<UserDto>> CreateUser([FromBody] CreateUserRequest request, CancellationToken ct)
{
    // Server owns these fields
    var user = new User
    {
        Id = Ulid.NewUlid(),
        Name = request.Name,
        Email = request.Email,
        PasswordHash = _passwordHasher.HashPassword(request.Password),
        CreatedAt = DateTime.UtcNow,
        IsActive = true,
        Role = UserRole.User
    };
    
    _db.Users.Add(user);
    await _db.SaveChangesAsync(ct);
    return CreatedAtAction(nameof(GetUser), new { id = user.Id }, user.ToDto());
}
```

## Query parameters: validate and sanitize

Route values, query strings, and headers can be manipulated by clients. Validate them before use:

- Route parameters (e.g., `{id}`) should be validated for format and existence
- Query strings should have bounded ranges and allowlisted values
- Headers should match expected patterns

```csharp
// non-compiling: illustrative
// WRONG: no validation on route parameter
[HttpGet("users/{id}")]
public async Task<IActionResult> GetUser(int id) // accepts negative, zero, very large numbers
{
    var user = await _db.Users.FindAsync(id);
    return user == null ? NotFound() : Ok(user.ToDto());
}

// RIGHT: validate route parameter
[HttpGet("users/{id}")]
public async Task<IActionResult> GetUser([FromRoute] int id)
{
    if (id <= 0)
        return BadRequest("Invalid user ID");
    
    var user = await _db.Users.FindAsync(id);
    return user == null ? NotFound() : Ok(user.ToDto());
}

// For GUID/ULID identifiers, use proper validation
[HttpGet("users/{id}")]
public async Task<IActionResult> GetUser([FromRoute] string id)
{
    if (!Ulid.TryParse(id, out _) && !Guid.TryParse(id, out _))
        return BadRequest("Invalid ID format");
    
    var user = await _db.Users.FindAsync(id);
    return user == null ? NotFound() : Ok(user.ToDto());
}
```

## File uploads: validate everything

File uploads are user input. Validate:
- File extension against an allowlist
- Content type against an allowlist
- File size against a maximum
- File content (magic numbers) to prevent polyglot files
- Never trust the original filename for storage

```csharp
// non-compiling: illustrative
private static readonly HashSet<string> AllowedExtensions = new(StringComparer.OrdinalIgnoreCase)
{
    ".jpg", ".jpeg", ".png", ".gif", ".pdf"
};

private static readonly HashSet<string> AllowedContentTypes = new(StringComparer.OrdinalIgnoreCase)
{
    "image/jpeg", "image/png", "image/gif", "application/pdf"
};

[HttpPost("upload")]
public async Task<IActionResult> UploadFile(IFormFile file, CancellationToken ct)
{
    if (file == null || file.Length == 0)
        return BadRequest("No file provided");
    
    if (file.Length > 10_000_000) // 10MB
        return BadRequest("File too large");
    
    var extension = Path.GetExtension(file.FileName);
    if (string.IsNullOrEmpty(extension) || !AllowedExtensions.Contains(extension))
        return BadRequest("Invalid file type");
    
    var contentType = file.ContentType;
    if (string.IsNullOrEmpty(contentType) || !AllowedContentTypes.Contains(contentType))
        return BadRequest("Invalid content type");
    
    // Validate magic numbers
    using var ms = new MemoryStream();
    await file.CopyToAsync(ms, ct);
    if (!IsValidFileFormat(ms.ToArray(), extension))
        return BadRequest("Invalid file content");
    
    // Store with server-generated name
    var fileName = $"{Guid.NewGuid()}{extension}";
    var path = Path.Combine("uploads", fileName);
    await using (var fs = new FileStream(path, FileMode.Create))
    {
        ms.Position = 0;
        await ms.CopyToAsync(fs, ct);
    }
    
    return Ok(new { fileName });
}
```

## Command injection: sanitize file paths and command arguments

Never pass unvalidated user input to:
- File operations (`File.Open`, `Directory.CreateDirectory`)
- Process execution (`Process.Start`, `IHostedService` commands)
- Dynamic library loading
- Environment variables from user input

```csharp
// WRONG: path traversal
[HttpGet("download")]
public IActionResult DownloadFile([FromQuery] string fileName)
{
    var path = Path.Combine("user-files", fileName); // ../etc/passwd possible
    return PhysicalFile(path, "application/octet-stream");
}

// RIGHT: allowlist and sanitize
[HttpGet("download")]
public IActionResult DownloadFile([FromQuery] string fileName)
{
    var allowedFiles = new HashSet<string> { "report.pdf", "data.csv", "image.jpg" };
    if (!allowedFiles.Contains(fileName))
        return BadRequest("Invalid file");
    
    var path = Path.Combine("user-files", fileName);
    if (!System.IO.File.Exists(path))
        return NotFound();
    
    return PhysicalFile(path, "application/octet-stream");
}
```

## Validation tools and patterns

Use the right tool for the job:

- **FluentValidation**: Rich validation rules, async validators, complex scenarios
  ```csharp
  public class CreateUserRequestValidator : AbstractValidator<CreateUserRequest>
  {
      public CreateUserRequestValidator()
      {
          RuleFor(x => x.Email).EmailAddress();
          RuleFor(x => x.Password).MinimumLength(8);
          RuleFor(x => x.Name).NotEmpty().MaximumLength(100);
      }
  }
  ```

- **DataAnnotations**: Simple validation, works with model binding
  ```csharp
  public record CreateUserRequest(
      [Required, EmailAddress] string Email,
      [Required, MinLength(8)] string Password,
      [Required, MaxLength(100)] string Name
  );
  ```

- **Manual validation**: When you need custom logic or early rejection
  ```csharp
  [HttpPost]
  public async Task<IActionResult> Create([FromBody] CreateUserRequest request, CancellationToken ct)
  {
      if (await _userService.EmailExistsAsync(request.Email, ct))
          return Conflict("Email already in use");
      
      if (!request.Password.IsStrongPassword())
          return BadRequest("Password not strong enough");
      
      // ...
  }
  ```

## Summary: the validation checklist

When reviewing API boundary code, ask:

1. **Are entities returned or accepted at the boundary?** → Reject (mass assignment)
2. **Is raw SQL used with string concatenation or interpolation?** → Reject (SQL injection)
3. **Are pagination parameters unbounded or unvalidated?** → Reject (memory/DoS risk)
4. **Are route/query/header parameters validated?** → If not, reject
5. **Are file uploads validated for type, size, and content?** → If not, reject
6. **Is user input used in file paths, commands, or dynamic SQL identifiers?** → If yes without allowlist, reject

The rule: **Validate everything, trust nothing.**


## Logging

## Structured logging, or it did not happen

Message templates with named placeholders, never interpolation:

```csharp
// non-compiling: illustrative
// WRONG: one opaque string; unsearchable, allocates even when Info is filtered out
_logger.LogInformation($"Order {order.Id} shipped to {order.Country}");
// RIGHT: queryable fields OrderId and Country, zero cost when the level is off
_logger.LogInformation("Order {OrderId} shipped to {Country}", order.Id, order.Country);
```

Interpolated strings pay formatting and boxing before the level check; templates defer both. More importantly, `OrderId` becomes a field you can filter on in Seq/ELK/App Insights - `$"..."` produces N unique strings that group as N distinct messages.

Rules:
- Placeholder names are PascalCase and consistent codebase-wide: pick `OrderId` once; `orderId`, `order_id`, and `Id` in different call sites split the same field three ways.
- Never pass a whole entity as a placeholder value - `{Order}` calls `ToString()` (useless) or, with `{@Order}` destructuring, serializes every property including the ones you must not log (below).
- CA2254 ("template should be a static expression") as error: a variable template defeats the entire mechanism.

## Levels have meanings

- **Trace/Debug**: developer forensics, off in production by default. Payload dumps live here or nowhere.
- **Information**: business-meaningful events - order placed, payment captured, user registered. Not "entering method X"; that is what tracing is for.
- **Warning**: something degraded but handled - retry succeeded, fallback used, config missing with default applied. A warning nobody would act on is Information.
- **Error**: an operation failed and someone should look. Every Error log is a potential alert; logging expected validation failures as Error trains the on-call to ignore the channel.
- **Critical**: the process or a core dependency is going down.

Threshold: a request that succeeds end-to-end produces at most 1-2 Information lines. Ten Info logs per request is Debug wearing the wrong level.

## Exceptions

Pass the exception object as the first argument - `_logger.LogError(ex, "Importing row {Row} failed", i)` - never `ex.Message` interpolated into the template (loses type, stack, and inner exceptions). Log an exception at exactly one layer: the boundary that handles it. Catch-log-rethrow at every level produces four stack traces for one failure and quadruples the perceived error rate.

## What never goes in a log

Passwords, tokens, API keys, connection strings, full card numbers, session cookies, raw request bodies of auth endpoints, and personal data beyond what the retention policy covers. Specific traps:
- `{@Request}` destructuring a DTO that has a `Password` property.
- Logging `HttpRequestException` context including the URL when the URL carries a token in the query string.
- EF Core `EnableSensitiveDataLogging()` outside Development - it puts parameter values (i.e. user data) into logs.

Mark sensitive fields un-loggable structurally (redacting destructuring policies, `[LogPropertyIgnore]` with the source-generated logger) rather than relying on authors remembering.

## Correlation and scope

- One correlation id per request, propagated to outbound calls (`traceparent` header - ASP.NET Core + HttpClient do this automatically once OpenTelemetry or Activity propagation is on). A log line that cannot be joined to its request is decoration.
- `ILogger.BeginScope` attaches ambient fields (`OrderId`, `TenantId`) to every log inside the block - use it at operation entry instead of repeating the id in every template.
- Background jobs: request correlation dies at the queue boundary unless you carry it - store the trace context in the message envelope and restore it in the consumer.

## Hot paths and source generators

Per-call `params object[]` allocation is real in tight loops: use `[LoggerMessage]` source-generated logging for hot-path log sites (zero-allocation, compile-checked templates). Guard expensive value computation with `if (_logger.IsEnabled(LogLevel.Debug))` - the guard is free; building a debug dump string that gets filtered is not.

## Metrics vs logs

A counter incremented per event you would otherwise grep-and-count (`orders_placed_total`, `cache_misses`) belongs in `System.Diagnostics.Metrics.Meter`, not in log volume. Review flag: dashboards built by parsing log messages - that is a metric with extra steps and a fragile regex.


## Memory

## Managed leaks are reachability bugs

The GC collects what is unreachable; a ".NET memory leak" is always something still holding a reference - usually a long-lived object (static, singleton, cache) pointing at things meant to be short-lived. Review long-lived state with one question: "what removes entries from this?"

## Event handlers: the classic

`publisher.Event += subscriber.Handler` stores a reference to the subscriber inside the publisher. Long-lived publisher + short-lived subscriber = every subscriber ever, retained:

```csharp
// non-compiling: illustrative
// WRONG: scoped service subscribing to a singleton's event - one leaked scope graph per request
public OrderProcessor(GlobalEvents events) => events.OrderPlaced += OnOrderPlaced;
// RIGHT: unsubscribe symmetrically - which means the type is IDisposable
public void Dispose() => _events.OrderPlaced -= OnOrderPlaced;
```

Review flags: any `+=` on an event of a longer-lived object without the matching `-=` in Dispose; `static event` (subscribers live until process exit); lambda subscriptions (`events.X += (s, e) => ...`) that can never be unsubscribed because the delegate instance is gone. Prefer not having the mismatch at all: singleton-to-singleton events are fine; cross-lifetime notification is better served by `Channel<T>`/messaging than events.

## The other repeat offenders

- **Static/singleton collections as ad-hoc caches**: `static Dictionary<Guid, UserState>` with adds and no eviction is a leak with a business justification. Real cache types with bounds (`IMemoryCache` + `SizeLimit`, `MemoryCacheEntryOptions` expirations) - an unbounded cache is a leak with a nicer name (performance skill).
- **Timers**: `System.Threading.Timer`/`System.Timers.Timer` root their callback (and its captured `this`) until disposed. A timer field on a non-disposed object keeps the whole object alive - and the timer keeps firing against it.
- **CancellationTokenRegistration**: `token.Register(callback)` on a long-lived token (app shutdown token, a linked source that outlives the operation) accumulates one registration per call forever. Dispose registrations (`using var reg = token.Register(...)`, or `CancellationTokenRegistration.Unregister`), and dispose linked `CancellationTokenSource`s - each links registrations into its parents.
- **Closure captures**: a lambda stored long-term (cache value factory, event, callback registry) captures its enclosing locals - including that 200MB parsed document you only needed for one field. Extract the field before the lambda; capture the minimum. Same mechanism as `static` lambda guidance in the performance skill, different failure: there it is allocation rate, here it is retention.
- **Async state machines held by pending operations**: a `TaskCompletionSource` that is never completed roots every awaiter's stack. Every TCS needs a timeout/cancellation path to guaranteed completion.
- **String/array slices in old code**: `Substring` copies (fine); `Memory<T>.Slice` over a rented or huge array retains the whole backing array while the slice lives - do not store slices of pooled buffers past the return.

## LOH and fragmentation

Objects >= 85KB land on the Large Object Heap - collected only with Gen2, not compacted by default. Per-request `new byte[1MB]` buffers or giant `MemoryStream`s mean Gen2 pressure and fragmentation that looks like a leak in working-set graphs. Fixes in order: stream instead of buffering (serialization skill), `ArrayPool` for transient large buffers, `RecyclableMemoryStream` for repeated stream use.

## Diagnose before you patch

Memory "leaks" get fixed by guesswork more than any other bug class; the tooling makes guessing unnecessary:

```sh
dotnet-counters monitor -p <pid> --counters System.Runtime   # heap sizes, gen0/1/2 rates, % time in GC
dotnet-gcdump collect -p <pid>                                # heap snapshot, safe-ish in prod
```

Method: two gcdumps separated by the suspected growth period, diff by retained size (Visual Studio / PerfView / `dotnet-heapview`) - the leaking type and its retention path to a root fall out directly; the fix is severing that path. Rules of engagement:
- Rising working set alone is not a leak - the GC keeps committed memory it expects to reuse, and Server GC idles high by design. Leak = Gen2/LOH size growing monotonically across many Gen2 collections under steady load.
- `GC.Collect()` in application code to "fix" memory: rejection. It masks the retention bug, stalls the process, and defeats the GC's own tuning. Legitimate only in measurement harnesses.
- Container limits: the GC reads cgroup limits; a container OOMKilled with a small heap usually means non-GC memory (native deps, buffers, sockets) or a limit set below baseline - check `GCHeapHardLimit` math before blaming the app.
- Every leak fix ships with the evidence: the gcdump diff before, flat line after. "Restarted nightly as a workaround" is an incident deferral, not a fix - say so in the ticket.


## Middleware

## Order is the contract

Middleware runs in registration order on the way in, reverse on the way out. Most pipeline bugs are ordering bugs, and they fail silently - a misplaced middleware doesn't throw, it just doesn't apply. The canonical order:

```csharp
app.UseExceptionHandler();       // first: catches everything below
app.UseHsts();                   // prod only
app.UseHttpsRedirection();
app.UseStaticFiles();            // before auth deliberately - or after, if files need auth (decide!)
app.UseRouting();
app.UseCors();                   // after routing, before auth
app.UseAuthentication();         // WHO you are
app.UseAuthorization();          // WHAT you may do - always after authentication
app.MapControllers();
```

Review flags with their failure modes:
- `UseAuthorization` before `UseAuthentication`: authorization evaluates an anonymous principal - `[Authorize]` returns 401 for valid tokens, or worse, policies keyed on claims all fail open/closed confusingly.
- `UseCors` after `UseAuthentication`: preflight OPTIONS requests (which carry no credentials) hit auth and die with 401 - the browser reports it as a CORS error and someone "fixes" it by allowing anonymous.
- `UseExceptionHandler` anywhere but first: exceptions from middleware above it escape as raw 500s with no ProblemDetails and no logging.
- `UseStaticFiles` placement is a decision, not a default: before auth means every file is public - fine for CSS, an incident for `/files/contracts/`. Files needing authorization are served through an endpoint, not `UseStaticFiles`.

## Endpoint-level cross-cutting: filters, not middleware

Middleware sees `HttpContext` and runs for every request; it does not know which endpoint matched (before `UseRouting`) or its metadata. Logic that needs the endpoint, model state, or action arguments belongs in endpoint filters / action filters / `[Authorize]` policies. A middleware doing `if (context.Request.Path.StartsWithSegments("/api/admin"))` is hand-rolled routing - it silently misses `/API/Admin` (or doesn't, depending on case settings), breaks on route changes, and is invisible to endpoint metadata tooling. Path-prefix auth checks in middleware are a rejection; that is what authorization policies applied to route groups are for.

## Custom middleware pitfalls

```csharp
public async Task InvokeAsync(HttpContext context, RequestDelegate next)
{
    // WRONG: reading the body without buffering consumes it - model binding downstream gets an empty stream
    using var reader = new StreamReader(context.Request.Body);
    var body = await reader.ReadToEndAsync();
    await next(context);
}
```

- Reading the request body: `context.Request.EnableBuffering()` first, read, then `Body.Position = 0`. And cap what you read - buffering a 500MB upload to log it is self-DoS.
- Writing to the response after `next()` when the response has started (`context.Response.HasStarted`) throws. Headers must be set before the first body byte; use `OnStarting` callbacks for late headers.
- Constructor-injected scoped services in conventional middleware: middleware is a singleton; scoped dependencies go as `InvokeAsync` parameters (the framework resolves them per request). Constructor injection of a `DbContext` into middleware is the captive-dependency bug (DI skill) in its most common costume.
- Swallowing exceptions in middleware "to keep the pipeline alive": the exception handler above you exists for that; catch only what you can translate, rethrow the rest.
- Not calling `next()` is legitimate short-circuiting (auth, rate limiting) - but then you own writing a complete response, including status code and content type.

## The pipeline is per-request; branches are static

`app.UseWhen(ctx => ...)` / `app.Map(...)` build the branch once at startup - the predicate runs per request, the builder lambda does not. Feature-flag checks inside the builder lambda evaluate once at boot and never again; per-request toggling goes inside the middleware itself.

## Review checklist

- Every middleware between `UseRouting` and `MapX` justified - that slot is for things needing route data (CORS, auth, rate limiting, output cache).
- `app.UseDeveloperExceptionPage()` / Swagger UI inside `if (app.Environment.IsDevelopment())` - exception detail pages in production leak stack frames and connection strings (exception skill).
- Response-buffering middleware (compression, caching) declared before things that write - order determines whether they see the bytes.
- Rate limiting (`UseRateLimiter`) present on auth endpoints and anything expensive-per-call; after auth if limits are per-user, before if per-IP.
- Health checks (`MapHealthChecks`) excluded from auth, logging noise, and rate limits deliberately - and not running real dependency checks on the liveness probe (a DB blip should fail readiness, not get the pod killed).


## Nullability

## Baseline

`<Nullable>enable</Nullable>` project-wide plus `<WarningsAsErrors>nullable</WarningsAsErrors>`. Warnings-as-suggestions rot in a week. For gradual migration, enable per-file with `#nullable enable` starting from the leaves (models, utilities) upward, and never add new files without it.

## The annotation is a contract, not a wish

- `string Name` means never null - and the type must make it true: initialized at construction (`required`, constructor parameter) or the annotation is a lie the compiler will now defend.
- `string? Name` means callers MUST handle null. Do not add `?` to silence a warning when the value is logically always present - fix the initialization instead.

```csharp
// non-compiling: illustrative
// WRONG: lying to the compiler to make the warning go away
public string Email { get; set; } = null!;
// RIGHT: the contract is enforced at construction
public required string Email { get; set; }
```

`= null!` is acceptable in exactly two places: EF Core navigation properties (materializer sets them) and DI-populated framework hooks. Each occurrence outside those needs a comment saying why.

## Null-forgiving operator audit

Every `!` is a claim: "I know more than the flow analysis." In review, verify the claim:
- `dict[key]!` after `ContainsKey` - fine, but `TryGetValue` removes the need.
- `FirstOrDefault()!` - almost always wrong; if absence is impossible use `First()` (fails loudly at the right place), if possible, handle it.
- `!` on deserialized input (`JsonSerializer.Deserialize<T>(json)!`) - wrong: deserialization of `"null"` returns null; validate and throw a domain-meaningful error.

Grep the diff for `!.` and `)!` - more than a couple per file means the types are misdesigned, usually a half-initialized object that needs a constructor or a factory.

## Boundaries: annotations do not validate

Nullable analysis is compile-time only. Data crossing a trust boundary (HTTP body, message queue, database, config) arrives unchecked:
- Request DTOs: non-null annotation + `[Required]`/validator. ASP.NET Core model validation treats non-nullable reference properties as required by default - know this, because it produces 400s people then "fix" by adding `?` everywhere.
- Public library APIs: keep `ArgumentNullException.ThrowIfNull(arg)` on entry points; your consumers may compile with nullable off.

## EF Core interaction

- Non-nullable property => NOT NULL column; `string?` => NULL. Check migrations after annotation changes - adding `?` is a schema change.
- Required navigation: `public Customer Customer { get; set; } = null!;` - and remember it is still null when the entity was loaded without Include; the annotation does not load data. A `NullReferenceException` on a "non-nullable" navigation means a missing Include or projection, not a data bug.
- Optional relationship: both FK and navigation nullable (`int? CustomerId`, `Customer? Customer`), and they must agree - a non-nullable navigation over a nullable FK misleads every reader.

## Patterns to prefer

- `is null` / `is not null` over `== null` (bypasses operator overloads, reads as intent).
- Early return over nested null checks; after `if (x is null) return;` flow analysis promotes `x` for the rest of the method.
- `[NotNullWhen(true)]`, `[MemberNotNull(nameof(_field))]` on Try-patterns and init helpers so callers do not need `!`:

```csharp
public bool TryGetUser(int id, [NotNullWhen(true)] out User? user)
```

- `??` with a throw for impossible states: `var user = cache.Get(id) ?? throw new InvalidOperationException($"User {id} evicted mid-request");` - fails at the assumption, not three frames later.

## What not to do

- Do not blanket-`?` a legacy codebase to make it compile; that erases the information the feature exists to capture.
- Do not null-check parameters the annotation already guarantees inside private/internal code - checks belong at trust boundaries, not on every frame.


## Performance

## First: does this code path earn optimization?

Optimize code that is (a) per-request or per-item in a hot loop, and (b) shown hot by a profiler or allocation trace - `dotnet-trace`, `dotnet-counters`, PerfView, or a BenchmarkDotNet micro-benchmark for the disputed snippet. Reject performance PRs justified by vibes, and equally reject "premature optimization" as an excuse for gratuitous waste in known-hot paths (serializers, middleware, per-row parsing). Startup code, admin endpoints, and once-a-day jobs get readability, not Spans.

The usual ranking of real wins: eliminate I/O (N+1, chatty HTTP, missing cache) >> reduce allocations >> micro-optimize CPU. A `Span<T>` refactor is noise next to an uncached per-request database call.

## Allocation review flags

- **Closures in hot paths**: a lambda capturing locals allocates a closure object per call. Use static lambdas with state parameters where the API offers them: `ConcurrentDictionary.GetOrAdd(key, static (k, arg) => Create(k, arg), arg)`.
- **LINQ in per-item loops**: each chained operator allocates an enumerator/iterator. `items.Where(...).Select(...).ToList()` once per request is fine; inside a loop over 100k rows, write the `foreach`. Also `Any()` on an `ICollection` - use `.Count > 0` (no enumerator).
- **params / interface enumeration**: `params object[]` allocates an array per call (logging!); `foreach` over `IEnumerable<T>` boxes the enumerator when the concrete type's is a struct - iterate the concrete `List<T>` in hot code.
- **Boxing**: value types passed as `object`/non-generic interfaces, string interpolation of structs into loggers. Use structured logging templates - `_logger.LogInformation("Order {Id}", id)` - which also skip formatting entirely when the level is off; interpolated `$"..."` pays even when filtered. Wrap expensive log-value computation in `if (_logger.IsEnabled(LogLevel.Debug))`.

## Strings

- Concatenation in a loop is O(n^2): `StringBuilder`, or `string.Create` when the final length is known.
- Parsing/slicing hot text: `ReadOnlySpan<char>` + `span.Slice`/`IndexOf` instead of `Substring` chains - zero allocations vs one string per slice. `int.Parse(span)` overloads exist for exactly this.
- Case-insensitive compare: `string.Equals(a, b, StringComparison.OrdinalIgnoreCase)`, never `a.ToLower() == b.ToLower()` (two allocations plus culture pitfalls).

## Span, Memory, pooling

- `Span<T>`/`stackalloc` for small (<=1KB) transient buffers in synchronous code. `Span` cannot live across `await`; use `Memory<T>` there.
- `ArrayPool<T>.Shared.Rent` for large transient buffers (I/O, encoding). Always return in `finally`, never return a buffer you still reference, and remember rented arrays are not cleared and may be oversized - use the length you asked for, not `.Length`.
- Repeated serialization targets: `RecyclableMemoryStream` or pooled `IBufferWriter<byte>` instead of `new MemoryStream()` per message.
- Structs: fine and beneficial small (<= ~16-24 bytes) and readonly; large mutable structs copied through method calls are a deoptimization. `readonly struct` prevents defensive copies under `in`.

## Collections and data

- Pre-size when count is known: `new List<T>(count)`, `new Dictionary<K,V>(count)` - growth is repeated array copies.
- Lookup in a loop over another collection: build a `Dictionary`/`HashSet` first; `list.Contains` inside `Where` is the in-memory N+1.
- `IEnumerable<T>` returned and enumerated twice re-executes the pipeline (or the query). Materialize once at the decision point.

## Caching (the actual big lever)

- `IMemoryCache` for per-instance hot reference data; set size limits or explicit expirations - an unbounded cache is a memory leak with a nicer name.
- Cache stampede: on expiry of a popular key, N concurrent requests all recompute. .NET 9+ `HybridCache` handles this (built-in stampede protection, plus L1/L2); otherwise a per-key semaphore/`Lazy<Task<T>>` pattern.
- Cache DTOs/immutable objects, never tracked EF entities (they capture a disposed context and cross-request state).

## Verify, then merge

Any PR claiming a performance improvement includes the before/after evidence: BenchmarkDotNet table for micro, or trace/latency numbers for macro. "Should be faster" is not a review artifact.


## Security

## Authentication is not authorization

Authentication answers "who is this"; authorization answers "may THEY do THIS to THAT resource". The standard failure: an endpoint behind `[Authorize]` that never checks the resource belongs to the caller.

- Every controller/endpoint group has an explicit auth posture. Set the fallback policy so unmarked endpoints are DENIED, and make anonymous access an explicit opt-in:

```csharp
builder.Services.AddAuthorizationBuilder()
    .SetFallbackPolicy(new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build());
```

- Role checks (`[Authorize(Roles = "Admin")]`) cover class-level access; resource-level access (this order, this document) requires a resource check in the handler - `IAuthorizationService.AuthorizeAsync(user, order, "OrderOwner")` or an ownership filter in the query itself.

## IDOR - the highest-yield finding in CRUD APIs

```csharp
// non-compiling: illustrative
// WRONG: any authenticated user reads any invoice by iterating ids
[HttpGet("{id}")]
public Task<InvoiceDto?> Get(int id) => _db.Invoices.Where(i => i.Id == id).ProjectToDto().FirstOrDefaultAsync();
// RIGHT: ownership is part of the query, absence is 404 (don't leak existence via 403)
public Task<InvoiceDto?> Get(int id) => _db.Invoices
    .Where(i => i.Id == id && i.CustomerId == _currentUser.CustomerId)
    .ProjectToDto().FirstOrDefaultAsync();
```

Review every endpoint taking an id: where is the tenancy/ownership predicate? In multi-tenant systems, prefer EF global query filters (`HasQueryFilter(e => e.TenantId == tenantProvider.TenantId)`) so a forgotten `Where` fails safe - and audit every `IgnoreQueryFilters()` call as a privileged operation. Sequential ints make IDOR trivially enumerable; that argues for GUIDs/ULIDs on exposed ids, but random ids are obscurity, not authorization - the predicate is still required.

## Mass assignment / over-posting

Binding request bodies to entities lets clients set any column: `{"name":"x","isAdmin":true,"balance":9999}`. Bind to request DTOs containing exactly the client-settable fields; map explicitly. The same applies to updates: `PATCH`/`PUT` handlers that copy all incoming properties onto the entity (`_mapper.Map(request, entity)` with a permissive profile) need a field-by-field review. Server-owned fields - id, timestamps, owner, role, state - are never bound from input.

## SQL injection

Parameterization is the only defense; EF LINQ is parameterized automatically. The dangerous surface is raw SQL:

```csharp
// non-compiling: illustrative
// WRONG: interpolation into the SQL string
var users = db.Users.FromSqlRaw($"SELECT * FROM Users WHERE Name = '{name}'");
// RIGHT: FromSql / FromSqlInterpolated turns interpolation holes into parameters
var users = db.Users.FromSql($"SELECT * FROM Users WHERE Name = {name}");
```

`FromSqlRaw`/`ExecuteSqlRaw` with string concatenation or `string.Format` is a rejection. Watch the copy-paste trap: moving an interpolated string from `FromSql` (safe) to `FromSqlRaw` (now injectable) compiles cleanly. Identifiers (table/column names, ORDER BY direction) cannot be parameterized - allowlist them against a fixed set, never pass through. Same rules for Dapper: values via anonymous-object parameters, identifiers via allowlist.

## Secrets and data exposure

- No credentials in source or config files (see configuration-and-secrets). In review, grep diffs for literal keys/tokens/passwords.
- Exception details, stack traces, and EF error messages never reach response bodies in production - global handler returns ProblemDetails with a correlation id.
- Logging: no passwords, tokens, full card numbers, or session cookies in log statements; structured-log whole-object dumps (`{@request}`) are the common leak.
- Responses: returning entities exposes columns you forgot were sensitive (password hashes, internal flags). DTO projection is a security control, not just hygiene.

## Input handling and platform hardening

- Deserialization: never `BinaryFormatter` (RCE, removed for a reason) and no `TypeNameHandling.All`/`JsonSerializerSettings` with polymorphic type names on untrusted input (gadget-chain RCE). System.Text.Json with explicit `[JsonDerivedType]` discriminators is the safe polymorphism.
- File uploads: validate extension AND content type against an allowlist, cap size, store outside the web root under server-generated names; never trust `FileName` for the path (`../` traversal).
- SSRF: any endpoint fetching a user-supplied URL needs an allowlist of hosts/schemes; block private ranges and redirects to them.
- CSRF: cookie-authenticated state-changing endpoints need antiforgery tokens; pure bearer-token APIs do not, but then `SameSite` and CORS config carry the weight - CORS with `AllowAnyOrigin` plus credentials is misconfiguration (the framework rejects the combination; wildcard-reflecting origins by hand recreates it).
- Password handling: ASP.NET Core Identity or `PasswordHasher<T>`; hand-rolled SHA256(password) is a finding regardless of salt.


## Serialization

## One options instance, defined once

`JsonSerializerOptions` caches type metadata; a new instance per call rebuilds it every time - a real, measured hot-path cost. Define the codebase's options once (static readonly, or via `ConfigureHttpJsonOptions`/`AddJsonOptions` for ASP.NET Core) and reference it everywhere:

```csharp
// non-compiling: illustrative
// WRONG: metadata cache rebuilt per call, and settings drift per call site
return JsonSerializer.Serialize(dto, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
// RIGHT
public static class Json { public static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web); }
return JsonSerializer.Serialize(dto, Json.Web);
```

Two call sites with different casing policies for the same contract is a bug factory - the review flag is `new JsonSerializerOptions` anywhere outside composition/static init.

## Contracts evolve; plan for it in review

- Unknown incoming properties are silently dropped by default - good for forward compatibility, bad for security (see mass-assignment in the security skill) and for typo detection on internal contracts. For messages between your own services, `UnmappedMemberHandling = Disallow` turns silent contract drift into a loud failure.
- Renaming a property is a breaking change for every stored document and in-flight message, not just live callers. Additive evolution only: add the new property, keep reading the old one, migrate, then remove - the expand/contract pattern from the migrations skill applies to JSON too.
- Required fields: `required` properties / `JsonRequiredAttribute` make missing-field bugs fail at deserialization instead of as default-valued ghosts three layers later. A DTO where `Amount = 0` is indistinguishable from "amount was absent" will eventually charge someone zero.
- Enums: serialize as strings (`JsonStringEnumConverter`). Numeric enum wire values mean reordering the enum silently corrupts every stored payload; string values also survive adding members. Decide the unknown-value policy explicitly for incoming strings.

## Polymorphism without type-name injection

Never accept a type name from the payload to decide what to construct - that is the deserialization RCE class (`TypeNameHandling.All` in Newtonsoft, custom `Type.GetType(json["$type"])` resolvers). System.Text.Json's allow-listed discriminators are the safe version:

```csharp
[JsonPolymorphic(TypeDiscriminatorPropertyName = "type")]
[JsonDerivedType(typeof(CardPayment), "card")]
[JsonDerivedType(typeof(BankTransfer), "bank")]
public abstract record Payment;
```

The discriminator maps to a closed set you declared; an unknown value fails. Any deserializer configuration that can materialize arbitrary types from input data is a rejection regardless of how trusted the source claims to be - queues and databases are attacker-reachable in more incidents than anyone plans for.

## Large payloads: stream, don't buffer

- `JsonSerializer.SerializeAsync(stream, ...)` / `DeserializeAsync<T>(stream, ...)` against the request/response body, not `Serialize` to a string first - a string round-trip doubles memory and lands multi-MB payloads on the LOH.
- Reading a huge array of items for per-item processing: `JsonSerializer.DeserializeAsyncEnumerable<T>(stream, ct)` processes elements as they arrive instead of materializing the whole list.
- `HttpClient`: `ReadFromJsonAsync<T>()` streams; `ReadAsStringAsync()` then `Deserialize` buffers - the former, always, and it also respects the charset header.
- Inbound size limits exist and are deliberate: unbounded request bodies deserialized into object graphs are a memory-exhaustion vector. Depth limits too (`MaxDepth`) when input is hostile - default 64 is fine, `0`/unbounded is not.

## Round-trip honesty

- `decimal` for money survives JSON as a number in .NET-to-.NET, but JavaScript callers read it as double and corrupt cents on large values; same for `long` ids above 2^53. Contracts consumed by JS serialize money and snowflake ids as strings.
- `DateTime` without offset in payloads: see the datetime skill - require offsets on instant fields at the contract level.
- Reference cycles (EF entities with navigations both ways) throw or emit `$ref` garbage - the actual fix is never `ReferenceHandler.Preserve`, it is "stop serializing entities" (api-layer skill).
- Dictionary keys, `TimeSpan`, `char`: check the actual emitted JSON in a test. Contract shape is asserted by at least one snapshot/approval test per public contract, so a serializer upgrade or attribute change fails CI instead of production consumers.

## Source generation

AOT, trimming, or measured startup/throughput needs: `JsonSerializerContext` source generation. Otherwise reflection mode is fine - source-gen everywhere by default adds build complexity without a driver. If source-gen is on, `JsonSourceGenerationMode.Metadata` + options mismatch bugs (attribute says camelCase, context says default) are the thing to review.


## SOLID

## Single Responsibility

Trigger questions: how many reasons does this class change for, and who asks for each change? Concrete smells:
- Constructor takes 6+ dependencies. That is 6 collaborators' worth of reasons to change; split the use cases.
- Method groups with disjoint dependency usage: if `ImportUsers` uses `_csv` and `_repo`, while `SendDigest` uses `_email` and `_clock`, you have two classes cohabiting.
- Names containing `Manager`, `Helper`, `Util`, `Processor` plus a 500-line body. The name is vague because the responsibility is.

Do not over-apply: a class with three methods around one aggregate is fine. SRP violations are proven by change history (this file appears in every PR), not by line count alone.

## Open/Closed

The practical form: adding a new case should not require editing a switch that already shipped. Trigger: the same `switch (type)` appears in 2+ places.

```csharp
// SMELL: every new export format edits this switch and its twin in ValidateFormat
public byte[] Export(string format) => format switch
{
    "csv" => ExportCsv(), "xlsx" => ExportXlsx(), _ => throw new NotSupportedException()
};
// REFACTOR: strategy resolved from DI
public interface IExporter { string Format { get; } byte[] Export(ReportData d); }
// registration: services.AddSingleton<IExporter, CsvExporter>(); ... resolve IEnumerable<IExporter>
```

One switch in one place is fine - it IS the extension point. Extract only on the second occurrence. Do not pre-build plugin architectures for cases that never had a second implementation.

## Liskov Substitution

C#-specific violations to reject:
- Overrides throwing `NotSupportedException` or `NotImplementedException`: the type does not honor the contract; split the interface or fix the hierarchy. (`ReadOnlyCollection.Add` is the cautionary tale, not a license.)
- Override that strengthens preconditions: base accepts null/empty, derived throws. Callers coded against the base break.
- `if (x is SpecificDerived d)` in code that receives the base type - the hierarchy has failed and callers are re-dispatching manually. Push the varying behavior into the type.
- Async contract narrowing: base method is truly async, override returns `Task.FromResult` after blocking work, or vice versa - behavioral surprise under load counts as a substitution failure.

## Interface Segregation

- An interface with 10+ members where implementations throw or no-op half of them: split by consumer. The consumer defines the interface shape, not the implementer.
- Test doubles are the detector: if every test mocks the same 2 of 12 methods, those 2 are the real interface.
- One-interface-per-class-by-reflex (`IUserService` with exactly one implementation, extracted only for mocking) is not ISP - it is acceptable ceremony at the application boundary, noise everywhere else. Do not demand interfaces for classes with no second implementation and no test seam need.

## Dependency Inversion

- High-level policy referencing concrete infrastructure: an `OrderService` constructing `SmtpClient` or `HttpClient` inline. Depend on `IEmailSender` defined in the application layer, implemented in infrastructure.
- The interface lives with the CONSUMER (application layer), not next to its implementation in the infrastructure project - otherwise the dependency arrow still points the wrong way.
- `new` on anything with I/O, time, randomness, or configuration inside business logic: inject it (`TimeProvider` instead of `DateTime.UtcNow` where testability matters).
- DIP does not mean "interface everything": `List<T>`, DTOs, pure functions, and framework types need no abstraction. Abstract at volatility boundaries: I/O, third-party services, things you will swap or fake.

## Review verdict guidance

Flag a SOLID issue only with the concrete cost attached: "this switch is duplicated in X and Y, next format touches both" - not "violates OCP". If you cannot name the cost, it is not a finding.


## Testing

## Mocking DbContext is a smell

```csharp
// non-compiling: illustrative
// WRONG: mocking what you don't own, re-implementing the ORM in Moq
var mockSet = new Mock<DbSet<Order>>();
mockSet.As<IQueryable<Order>>().Setup(m => m.Provider).Returns(orders.Provider);
mockSet.As<IQueryable<Order>>().Setup(m => m.Expression).Returns(orders.Expression);
mockSet.As<IQueryable<Order>>().Setup(m => m.GetEnumerator()).Returns(orders.GetEnumerator());

var mockCtx = new Mock<ApplicationDbContext>();
mockCtx.Setup(c => c.Orders).Returns(mockSet.Object);

var service = new OrderService(mockCtx.Object);
```

This tests LINQ-to-Objects semantics, not SQL translation. EF Core's in-memory provider has the same flaw: no relational behavior, no transactions, no constraint enforcement. It catches only the simplest bugs and gives false confidence.

**Correct options, in order of preference:**
1. **Testcontainers** with the production engine; one container per test class/collection, `Respawn` or transactions for cleanup.
2. **SQLite in-memory** only when the model is compatible and speed genuinely blocks you - and keep a Testcontainers suite for the critical queries.
3. If a service must be tested without a database, mock a **repository interface YOU defined** - never the DbContext.

```csharp
// CORRECT: repository abstraction you control
public interface IOrderRepository
{
    Task<Order?> GetByIdAsync(int id, CancellationToken ct = default);
    Task AddAsync(Order order, CancellationToken ct = default);
    Task SaveChangesAsync(CancellationToken ct = default);
}

// Test doubles implement YOUR interface, not EF Core's
public class FakeOrderRepository : IOrderRepository
{
    private readonly List<Order> _orders = [];
    
    public Task<Order?> GetByIdAsync(int id, CancellationToken ct) =>
        Task.FromResult(_orders.FirstOrDefault(o => o.Id == id));
    
    public Task AddAsync(Order order, CancellationToken ct)
    {
        _orders.Add(order);
        return Task.CompletedTask;
    }
    
    public Task SaveChangesAsync(CancellationToken ct) => Task.CompletedTask;
}
```

## Asserting implementation details

```csharp
// non-compiling: illustrative
// WRONG: testing the mock, not the behavior
[Fact]
public void UpdateOrder_WhenCalled_CallsSaveChangesOnMock()
{
    var mockRepo = new Mock<IOrderRepository>();
    var service = new OrderService(mockRepo.Object);
    
    service.UpdateOrder(1, "New status");
    
    mockRepo.Verify(r => r.SaveChangesAsync(default), Times.Once); // 🚫 brittle
}
```

This test breaks when you refactor the service to call `SaveChanges` in a different method. It also doesn't verify the actual business outcome.

**Assert outcomes, not interactions:**

```csharp
// CORRECT: assert the state change
[Fact]
public async Task UpdateOrder_WhenCalled_UpdatesOrderStatus()
{
    // Arrange
    var order = new Order { Id = 1, Status = OrderStatus.Pending };
    var repo = new FakeOrderRepository();
    await repo.AddAsync(order, default);
    var service = new OrderService(repo);
    
    // Act
    await service.UpdateOrder(1, OrderStatus.Processing, default);
    
    // Assert
    var updated = await repo.GetByIdAsync(1, default);
    updated.Status.Should().Be(OrderStatus.Processing); // ✅ verifies behavior
}
```

## Task.Delay timing tests are flaky

```csharp
// non-compiling: illustrative
// WRONG: timing-dependent test that fails unpredictably
[Fact]
public async Task ProcessQueue_WhenCalled_ProcessesAfterDelay()
{
    var queue = new BackgroundQueue();
    queue.Enqueue("item");
    
    await Task.Delay(100); // 🚫 100ms is arbitrary
    
    queue.Count.Should().Be(0);
}
```

Timing tests are **environment-dependent**: CI runners are slower than dev machines, some machines are slower than others. They pass on your machine and fail in CI - or vice versa. They also slow down the suite and make it non-deterministic.

**Use synchronization primitives instead:**

```csharp
// CORRECT: await the actual condition
[Fact]
public async Task ProcessQueue_WhenCalled_ProcessesItem()
{
    var queue = new BackgroundQueue();
    var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    queue.Enqueue("item");
    
    // Wait for the queue to be processed
    while (queue.Count > 0 && !cts.IsCancellationRequested)
    {
        await Task.Delay(10, cts.Token); // small poll interval
    }
    
    queue.Count.Should().Be(0);
}

// Even better: expose a completion signal
public class BackgroundQueue
{
    private readonly Channel<string> _channel = Channel.CreateUnbounded<string>();
    public int Count => _channel.Reader.Count;
    
    public async Task ProcessAsync(CancellationToken ct)
    {
        await foreach (var item in _channel.Reader.ReadAllAsync(ct))
        {
            await ProcessItemAsync(item, ct);
        }
    }
}

// Test uses the signal
[Fact]
public async Task ProcessQueue_WhenCalled_ProcessesItem()
{
    var queue = new BackgroundQueue();
    var processing = queue.ProcessAsync(default);
    queue.Enqueue("item");
    
    await queue.WaitForCompletionAsync(); // ✅ deterministic
    
    // Assert state...
}
```

## Missing cancellation tokens in resilience tests

```csharp
// non-compiling: illustrative
// WRONG: resilience policy without cancellation token flow
[Fact]
public async Task MakePayment_WhenServiceUnavailable_Retries()
{
    var handler = new MockHttpMessageHandler(HttpStatusCode.ServiceUnavailable);
    var client = new HttpClient(handler);
    var resilience = new ResiliencePipelineBuilder()
        .AddRetry(new RetryStrategyOptions { MaxRetryAttempts = 3 })
        .Build();
    
    await resilience.ExecuteAsync(async _ => 
        await client.GetAsync("https://api.example.com/payments"), 
        CancellationToken.None); // 🚫 cancellation ignored
}
```

A timeout policy without the request token keeps calling dependencies for clients that already disconnected. The cancellation token is part of the **contract** between caller and callee.

**Flow the caller's token:**

```csharp
// CORRECT: propagate cancellation
[Fact]
public async Task MakePayment_WhenClientCancels_StopsRetrying()
{
    var handler = new MockHttpMessageHandler(HttpStatusCode.ServiceUnavailable);
    var client = new HttpClient(handler);
    var cts = new CancellationTokenSource();
    
    var resilience = new ResiliencePipelineBuilder()
        .AddRetry(new RetryStrategyOptions { MaxRetryAttempts = 100 })
        .Build();
    
    // Start the operation
    var task = resilience.ExecuteAsync(async ct => 
        await client.GetAsync("https://api.example.com/payments", ct),
        cts.Token);
    
    // Cancel immediately
    cts.CancelAfter(TimeSpan.Zero);
    
    await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
}
```

See also: **[http-resilience-and-outbound-calls](skills/http-resilience-and-outbound-calls/SKILL.md)** for timeout and retry policy rules.

## Testing async void and fire-and-forget

```csharp
// non-compiling: illustrative
// WRONG: async void cannot be awaited, exceptions are lost
public class OrderController : ControllerBase
{
    [HttpPost("orders")]
    public async void Post(OrderDto dto) // 🚫 async void
    {
        await _service.CreateOrderAsync(dto);
    }
}

// Test cannot catch the exception
[Fact]
public void Post_WhenInvalid_ReturnsBadRequest()
{
    var controller = new OrderController(_service);
    controller.ModelState.AddModelError("Name", "Required");
    
    controller.Post(new OrderDto()); // Exception swallowed
    
    Assert.Equal(400, controller.Response.StatusCode);
}
```

Async void exceptions are **lost** - they don't propagate to the test. They also make the controller non-composable (you can't await the endpoint).

**Return Task instead:**

```csharp
// CORRECT: async Task
[HttpPost("orders")]
public async Task<IActionResult> Post(OrderDto dto) // ✅ async Task
{
    if (!ModelState.IsValid)
        return BadRequest(ModelState);
    
    await _service.CreateOrderAsync(dto, HttpContext.RequestAborted);
    return Created(...);
}
```

## Testing synchronous code with async

```csharp
// non-compiling: illustrative
// WRONG: sync-over-async in tests
[Fact]
public void GetOrder_WhenCalled_ReturnsOrder()
{
    var service = new OrderService(_repo);
    var order = service.GetOrder(1).Result; // 🚫 .Result deadlocks under load
    
    Assert.NotNull(order);
}
```

`.Result` and `.Wait()` in tests cause **deadlocks** when the async code needs the synchronization context (which tests have). The thread pool is blocked waiting for itself.

**Use async all the way:**

```csharp
// CORRECT: async test
[Fact]
public async Task GetOrder_WhenCalled_ReturnsOrder()
{
    var service = new OrderService(_repo);
    var order = await service.GetOrderAsync(1, default); // ✅ proper async
    
    order.Should().NotBeNull();
}
```

## Testing private methods directly

```csharp
// non-compiling: illustrative
// WRONG: testing implementation, not behavior
public class OrderService
{
    private bool IsValid(Order order) => order.Total > 0;
}

[Fact]
public void IsValid_WhenTotalPositive_ReturnsTrue()
{
    var service = new OrderService();
    var method = typeof(OrderService).GetMethod("IsValid", BindingFlags.NonPublic | BindingFlags.Instance);
    var result = (bool)method.Invoke(service, [new Order { Total = 100 }]); // 🚫 brittle
    
    Assert.True(result);
}
```

Private methods are an **implementation detail**. If the behavior matters, expose it through a public method or extract a class. Testing private methods couples tests to refactoring.

**Test through public seams:**

```csharp
// CORRECT: test the public behavior
public class OrderService
{
    public Result ValidateOrder(Order order) // ✅ public method
    {
        if (order.Total <= 0)
            return Result.Fail("Total must be positive");
        return Result.Ok();
    }
}

[Fact]
public void ValidateOrder_WhenTotalZero_ReturnsFailure()
{
    var service = new OrderService();
    var result = service.ValidateOrder(new Order { Total = 0 });
    
    result.IsSuccess.Should().BeFalse();
}
```

## Testing concurrency with locks instead of synchronization

```csharp
// non-compiling: illustrative
// WRONG: testing lock behavior instead of business outcome
[Fact]
public void ProcessOrdersConcurrently_WhenCalled_UsesLocks()
{
    var service = new ConcurrentOrderService();
    var tasks = Enumerable.Range(1, 100)
        .Select(i => Task.Run(() => service.ProcessOrder(i)))
        .ToArray();
    
    Task.WaitAll(tasks); // 🚫 tests locks, not correctness
    
    service.OrdersProcessedCount.Should().Be(100);
}
```

This tests that locks exist, not that the business rule is correct. It also doesn't verify thread safety under real contention.

**Test the outcome, not the mechanism:**

```csharp
// CORRECT: test the invariant
[Fact]
public async Task ProcessOrdersConcurrently_WhenCalled_ProcessesAllOrders()
{
    var service = new ConcurrentOrderService();
    var orders = Enumerable.Range(1, 100).Select(i => new Order { Id = i }).ToList();
    
    var tasks = orders.Select(o => service.ProcessOrderAsync(o, default));
    await Task.WhenAll(tasks);
    
    var processed = await service.GetProcessedOrdersAsync(default);
    processed.Should().HaveCount(100); // ✅ verifies the invariant
}
```

See also: **[concurrency-and-shared-state](skills/concurrency-and-shared-state/SKILL.md)** for lock discipline and async mutual exclusion rules.

## Testing background services without proper cleanup

```csharp
// non-compiling: illustrative
// WRONG: background service test without proper lifecycle
[Fact]
public async Task BackgroundService_WhenStarted_ProcessesItems()
{
    var service = new OrderProcessingService(_repo);
    var host = new HostBuilder()
        .ConfigureServices(sc => sc.AddHostedService(_ => service))
        .Build();
    
    await host.StartAsync();
    await Task.Delay(100); // 🚫 arbitrary delay
    await host.StopAsync();
    
    _repo.Verify(r => r.SaveChangesAsync(default), Times.AtLeastOnce);
}
```

Background service tests need proper lifecycle management: start, wait for work, verify, stop. Arbitrary delays make tests flaky and slow.

**Use synchronization primitives:**

```csharp
// CORRECT: use completion signals
[Fact]
public async Task BackgroundService_WhenStarted_ProcessesItems()
{
    var service = new OrderProcessingService(_repo);
    var host = new HostBuilder()
        .ConfigureServices(sc => sc.AddHostedService(_ => service))
        .Build();
    
    await host.StartAsync();
    
    // Signal that work is complete
    await service.WaitForProcessingCompleteAsync(default);
    
    await host.StopAsync(TimeSpan.FromSeconds(5));
    
    _repo.Verify(r => r.SaveChangesAsync(default), Times.AtLeastOnce);
}
```

See also: **[background-work-and-hosted-services](skills/background-work-and-hosted-services/SKILL.md)** for background service lifecycle rules.

## Testing HTTP clients without IHttpClientFactory

```csharp
// non-compiling: illustrative
// WRONG: direct HttpClient construction
[Fact]
public async Task PaymentClient_WhenCalled_PostsToApi()
{
    var handler = new MockHttpMessageHandler();
    var client = new HttpClient(handler) { BaseAddress = new Uri("https://api.example.com") }; // 🚫 socket exhaustion
    var client = new PaymentClient(client);
    
    await client.ProcessPaymentAsync(new PaymentRequest(), default);
    
    handler.Protected().Verify(
        "SendAsync",
        Times.Once(),
        ItExpr.IsAny<HttpRequestMessage>(),
        ItExpr.IsAny<CancellationToken>());
}
```

Direct `new HttpClient()` construction causes **socket exhaustion** (each instance owns its handler and connections). In tests, this leaks resources between tests.

**Use IHttpClientFactory in tests too:**

```csharp
// CORRECT: factory-based construction
[Fact]
public async Task PaymentClient_WhenCalled_PostsToApi()
{
    var handler = new MockHttpMessageHandler();
    var services = new ServiceCollection();
    services.AddHttpClient<PaymentClient>(c => 
        c.BaseAddress = new Uri("https://api.example.com"))
        .AddHttpMessageHandler(() => handler);
    
    var provider = services.BuildServiceProvider();
    var client = provider.GetRequiredService<PaymentClient>();
    
    await client.ProcessPaymentAsync(new PaymentRequest(), default);
    
    handler.Protected().Verify(
        "SendAsync",
        Times.Once(),
        ItExpr.IsAny<HttpRequestMessage>(),
        ItExpr.IsAny<CancellationToken>());
}
```

See also: **[http-resilience-and-outbound-calls](skills/http-resilience-and-outbound-calls/SKILL.md)** for client construction and resilience policy rules.

## Testing without proper test data builders

```csharp
// non-compiling: illustrative
// WRONG: test with raw constructors and property soup
[Fact]
public async Task CreateOrder_WhenValid_CreatesOrder()
{
    var order = new Order
    {
        Id = 1,
        CustomerId = 42,
        Total = 100.50m,
        Status = OrderStatus.Pending,
        CreatedAt = DateTime.UtcNow,
        Items = [
            new OrderItem { ProductId = 1, Quantity = 2, Price = 50.25m },
            new OrderItem { ProductId = 2, Quantity = 1, Price = 0.00m }
        ]
    };
    
    var repo = new FakeOrderRepository();
    var service = new OrderService(repo);
    
    await service.CreateOrderAsync(order, default);
    
    var saved = await repo.GetByIdAsync(1, default);
    saved.Should().NotBeNull();
}
```

Raw constructors create **brittle tests** that break on every schema change. Setup duplication rots the suite.

**Use builders/object mothers:**

```csharp
// CORRECT: builder pattern
public static class OrderBuilder
{
    public static OrderBuilder Default => new OrderBuilder()
        .WithCustomer(42)
        .WithItem("Widget", 2, 50.25m);
    
    private readonly Order _order = new();
    
    public OrderBuilder WithCustomer(int id)
    {
        _order.CustomerId = id;
        return this;
    }
    
    public OrderBuilder WithItem(string name, int qty, decimal price)
    {
        _order.Items.Add(new OrderItem { ProductId = 1, Quantity = qty, Price = price });
        _order.Total += qty * price;
        return this;
    }
    
    public Order Build() => _order;
}

[Fact]
public async Task CreateOrder_WhenValid_CreatesOrder()
{
    var order = OrderBuilder.Default.Build();
    var repo = new FakeOrderRepository();
    var service = new OrderService(repo);
    
    await service.CreateOrderAsync(order, default);
    
    var saved = await repo.GetByIdAsync(1, default);
    saved.Should().NotBeNull();
    saved.Total.Should().Be(100.50m);
}
```

## Structural rules

- **One assertion per test** named for the behavior: `UpdateOrder_WhenAlreadyCancelled_ReturnsConflict`. A test named `Test1` fails uninformatively.
- **Deterministic tests**: inject `TimeProvider` (assert against `FakeTimeProvider`), fixed seeds, no `Task.Delay`-based synchronization - await a real condition or use `TaskCompletionSource`.
- **No logic in tests**: a loop or `if` in a test needs its own test. Parameterize with `[Theory]/[InlineData]` instead.
- **Test data setup** via builders/object mothers, not 30 lines of property soup copied between tests - setup duplication is why test suites rot after schema changes.
- **Flaky tests are P1**: quarantine within a day, fix or delete within a sprint. A suite people retry is a suite people ignore.

## See also

- **[testing-strategy](skills/testing-strategy/SKILL.md)** - Decide what to test at each layer of a .NET service
- **[concurrency-and-shared-state](skills/concurrency-and-shared-state/SKILL.md)** - Lock discipline and async mutual exclusion
- **[http-resilience-and-outbound-calls](skills/http-resilience-and-outbound-calls/SKILL.md)** - Timeout and retry policy rules
- **[background-work-and-hosted-services](skills/background-work-and-hosted-services/SKILL.md)** - Background service lifecycle rules

## What is worth testing, per layer

- **Domain logic** (calculations, state machines, invariants): unit tests, exhaustively. Pure code, no mocks needed, cheapest tests you own. If domain logic is hard to unit test, that is a design finding - it is entangled with I/O.
- **Application services**: test the orchestration decision points (authorization denial, conflict paths, event published on success) with mocked PORTS (your own interfaces: `IEmailSender`, `IPaymentGateway`). If a service is a pass-through to the repository, do not unit test it - the integration test covers it.
- **Data access (queries, mappings, migrations)**: integration tests against the real database engine via Testcontainers. This is non-negotiable for any nontrivial LINQ - translation bugs, collation, `DateTime` precision, and cascade behavior do not exist in fakes.
- **HTTP layer** (routing, binding, validation, auth wiring, ProblemDetails shape): `WebApplicationFactory` in-memory server tests. A controller unit test that mocks the service and asserts `Ok()` was returned tests nothing the compiler doesn't.
- **Not worth testing**: mappers with no logic, DTO property bags, framework behavior (does `[Required]` work), private methods directly (test through the public seam or extract a class).

## Mocking DbContext is a smell

```csharp
// non-compiling: illustrative
// WRONG: mocking what you don't own, re-implementing the ORM in Moq
var set = new Mock<DbSet<Order>>();
set.As<IQueryable<Order>>().Setup(m => m.Provider).Returns(orders.Provider);
mockCtx.Setup(c => c.Orders).Returns(set.Object);
```

This asserts your LINQ runs against LINQ-to-Objects, which has different semantics than the SQL translation (case sensitivity, null comparison, unsupported methods that pass in-memory and throw in production). The EF InMemory provider has the same flaw plus no relational behavior (no constraints, no transactions) - EF's own team advises against it. Correct options, in order of preference:
1. Testcontainers with the production engine; one container per test class/collection, `Respawn` or transactions for cleanup.
2. SQLite in-memory only when the model is compatible and speed genuinely blocks you - and keep a Testcontainers suite for the queries that matter.
3. If a service must be tested without a database, the boundary to mock is a repository interface YOU defined - never the DbContext.

## Test quality bar

- One behavior per test, named for it: `Ship_WhenOrderAlreadyCancelled_ReturnsConflict`. A test named `Test1` or asserting 14 things fails uninformatively.
- Arrange via builders/object mothers (`OrderBuilder.Paid().WithItems(3).Build()`), not 30 lines of property soup copied between tests - setup duplication is why test suites rot after schema changes.
- Assert outcomes, not interactions, wherever possible. `_repo.Verify(r => r.SaveAsync(...), Times.Once)` couples the test to implementation; asserting the order's state changed survives refactoring. Verify interactions only when the interaction IS the contract (email sent, event published).
- No logic in tests: a loop or `if` in a test needs its own test. Parameterize with `[Theory]/[InlineData]` instead.
- Deterministic: inject `TimeProvider` (assert against `FakeTimeProvider`), fixed seeds, no `Task.Delay`-based synchronization - awaiting a real condition or using `TaskCompletionSource`.

## Structural rules

- Coverage: use it to find untested critical paths, never as a target. 100% coverage of getters while the money-handling branch has one happy-path test is the standard failure mode. Review question: "which failure modes of this change have a test?"
- Speed budget: unit suite under ~10s, full integration suite minutes not hours - past that, developers stop running them and CI becomes the first execution.
- A flaky test is a P1 against the suite: quarantine within a day, fix or delete within a sprint. A suite people retry is a suite people ignore.
- Test project mirrors source structure; integration tests separated (project or trait) so `dotnet test --filter` can run units alone.
- When a production bug escapes, the fix PR contains the regression test that fails without the fix. No test, no merge.
