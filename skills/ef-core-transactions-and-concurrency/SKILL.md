---
name: ef-core-transactions-and-concurrency
description: Review EF Core write paths - transaction boundaries, optimistic concurrency tokens, lost updates, retry strategies vs user transactions, and multi-aggregate consistency. Use when reviewing SaveChanges patterns, transactions, or concurrent-write handling.
---

# EF Core Transactions and Concurrency

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
