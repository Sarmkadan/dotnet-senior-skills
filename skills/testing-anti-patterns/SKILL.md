---
name: testing-anti-patterns
description: Review .NET test code for common anti-patterns - mocking DbContext, asserting implementation details, Task.Delay timing, missing cancellation tokens, and brittle assertions. Use when reviewing test PRs or designing test suites.
---

# Testing Anti-patterns (.NET)

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
