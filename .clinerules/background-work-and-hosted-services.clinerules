# background-work-and-hosted-services

Review .NET background processing - BackgroundService loops, scoped dependency resolution, graceful shutdown, timers, queue consumption, and outbox patterns. Use when reviewing IHostedService, BackgroundService, recurring jobs, or queue consumers.

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
