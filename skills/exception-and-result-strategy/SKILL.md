---
name: exception-and-result-strategy
description: Decide when C# code should throw, when to return a Result type, what exceptions to define, and what must never be swallowed. Use when reviewing error handling, try/catch blocks, or designing failure contracts for services and APIs.
---

# Exception and Result Strategy

## The dividing line

- **Throw** for the exceptional: broken invariants, unreachable states, infrastructure failure, programmer error. The caller cannot meaningfully continue.
- **Return a result** for expected domain outcomes the caller must branch on: validation failure, "insufficient funds", "already exists", not-found in a lookup that legitimately misses.

The test: if the immediate caller would catch the exception and convert it to control flow, it should have been a return value. Exceptions-as-control-flow costs a stack capture per throw (~microseconds each - ruinous in loops) and hides branches from the reader.

```csharp
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
