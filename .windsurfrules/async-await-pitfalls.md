# async-await-pitfalls

Review C# async/await code for deadlocks, sync-over-async, async void, ValueTask misuse, fire-and-forget, and CancellationToken propagation. Use when writing or reviewing any async C# code.

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
