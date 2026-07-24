# memory-leaks-and-diagnostics

Review .NET code for managed memory leaks - event handler leaks, static caches, timers, CancellationTokenRegistration, closure captures - and how to diagnose with dotnet-counters/gcdump. Use when reviewing long-lived objects, event subscriptions, or investigating memory growth.

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
