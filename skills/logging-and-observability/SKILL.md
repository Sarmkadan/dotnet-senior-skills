---
name: logging-and-observability
description: Review .NET logging and observability - structured logging discipline, log levels, what not to log, correlation, exception logging, and metrics/tracing hooks. Use when reviewing ILogger usage, log statements, or diagnostics code.
---

# Logging and Observability

## Structured logging, or it did not happen

Message templates with named placeholders, never interpolation:

```csharp
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
