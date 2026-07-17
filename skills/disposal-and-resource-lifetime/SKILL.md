---
name: disposal-and-resource-lifetime
description: Review IDisposable/IAsyncDisposable usage in .NET - what to dispose, what never to dispose, using patterns, the dispose pattern itself, and finalizer rules. Use when reviewing resource management, using statements, or classes owning disposable fields.
---

# Disposal and Resource Lifetime

## The ownership rule

Whoever creates a disposable disposes it; whoever receives one does not. Every review question about disposal reduces to "who owns this instance?"

- Created in a method: `using` / `await using`, no exceptions.
- Created in a constructor and stored in a field: the class owns it, so the class implements `IDisposable` and disposes the field.
- Injected via DI: the container owns it. Disposing an injected `DbContext` or typed `HttpClient` breaks the next consumer of the same scoped instance. A class whose only disposables are injected does not implement `IDisposable` at all.

```csharp
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
