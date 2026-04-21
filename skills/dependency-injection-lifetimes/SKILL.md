---
name: dependency-injection-lifetimes
description: Review .NET dependency injection registrations for captive dependencies, scoped-in-singleton bugs, IServiceProvider abuse, disposal issues, and HttpClient registration. Use when writing or reviewing DI container registrations or constructor injection.
---

# Dependency Injection Lifetimes

## The one rule that causes 90% of DI bugs

A service must not depend on anything with a SHORTER lifetime. Singleton -> Scoped is the captive dependency: the singleton captures the first scope's instance forever.

```csharp
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
