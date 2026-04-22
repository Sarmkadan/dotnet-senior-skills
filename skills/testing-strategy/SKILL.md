---
name: testing-strategy
description: Decide what to test at each layer of a .NET service, when integration tests beat unit tests, why mocking DbContext is a smell, and what makes tests worth their maintenance cost. Use when writing tests, reviewing test PRs, or designing a test suite.
---

# Testing Strategy (.NET)

## What is worth testing, per layer

- **Domain logic** (calculations, state machines, invariants): unit tests, exhaustively. Pure code, no mocks needed, cheapest tests you own. If domain logic is hard to unit test, that is a design finding - it is entangled with I/O.
- **Application services**: test the orchestration decision points (authorization denial, conflict paths, event published on success) with mocked PORTS (your own interfaces: `IEmailSender`, `IPaymentGateway`). If a service is a pass-through to the repository, do not unit test it - the integration test covers it.
- **Data access (queries, mappings, migrations)**: integration tests against the real database engine via Testcontainers. This is non-negotiable for any nontrivial LINQ - translation bugs, collation, `DateTime` precision, and cascade behavior do not exist in fakes.
- **HTTP layer** (routing, binding, validation, auth wiring, ProblemDetails shape): `WebApplicationFactory` in-memory server tests. A controller unit test that mocks the service and asserts `Ok()` was returned tests nothing the compiler doesn't.
- **Not worth testing**: mappers with no logic, DTO property bags, framework behavior (does `[Required]` work), private methods directly (test through the public seam or extract a class).

## Mocking DbContext is a smell

```csharp
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
