---
name: middleware-and-pipeline-order
description: Review ASP.NET Core pipeline configuration - middleware ordering, auth placement, exception handling position, CORS, short-circuiting, and custom middleware pitfalls. Use when reviewing Program.cs pipeline setup or custom middleware.
---

# Middleware and Pipeline Order

## Order is the contract

Middleware runs in registration order on the way in, reverse on the way out. Most pipeline bugs are ordering bugs, and they fail silently - a misplaced middleware doesn't throw, it just doesn't apply. The canonical order:

```csharp
app.UseExceptionHandler();       // first: catches everything below
app.UseHsts();                   // prod only
app.UseHttpsRedirection();
app.UseStaticFiles();            // before auth deliberately - or after, if files need auth (decide!)
app.UseRouting();
app.UseCors();                   // after routing, before auth
app.UseAuthentication();         // WHO you are
app.UseAuthorization();          // WHAT you may do - always after authentication
app.MapControllers();
```

Review flags with their failure modes:
- `UseAuthorization` before `UseAuthentication`: authorization evaluates an anonymous principal - `[Authorize]` returns 401 for valid tokens, or worse, policies keyed on claims all fail open/closed confusingly.
- `UseCors` after `UseAuthentication`: preflight OPTIONS requests (which carry no credentials) hit auth and die with 401 - the browser reports it as a CORS error and someone "fixes" it by allowing anonymous.
- `UseExceptionHandler` anywhere but first: exceptions from middleware above it escape as raw 500s with no ProblemDetails and no logging.
- `UseStaticFiles` placement is a decision, not a default: before auth means every file is public - fine for CSS, an incident for `/files/contracts/`. Files needing authorization are served through an endpoint, not `UseStaticFiles`.

## Endpoint-level cross-cutting: filters, not middleware

Middleware sees `HttpContext` and runs for every request; it does not know which endpoint matched (before `UseRouting`) or its metadata. Logic that needs the endpoint, model state, or action arguments belongs in endpoint filters / action filters / `[Authorize]` policies. A middleware doing `if (context.Request.Path.StartsWithSegments("/api/admin"))` is hand-rolled routing - it silently misses `/API/Admin` (or doesn't, depending on case settings), breaks on route changes, and is invisible to endpoint metadata tooling. Path-prefix auth checks in middleware are a rejection; that is what authorization policies applied to route groups are for.

## Custom middleware pitfalls

```csharp
public async Task InvokeAsync(HttpContext context, RequestDelegate next)
{
    // WRONG: reading the body without buffering consumes it - model binding downstream gets an empty stream
    using var reader = new StreamReader(context.Request.Body);
    var body = await reader.ReadToEndAsync();
    await next(context);
}
```

- Reading the request body: `context.Request.EnableBuffering()` first, read, then `Body.Position = 0`. And cap what you read - buffering a 500MB upload to log it is self-DoS.
- Writing to the response after `next()` when the response has started (`context.Response.HasStarted`) throws. Headers must be set before the first body byte; use `OnStarting` callbacks for late headers.
- Constructor-injected scoped services in conventional middleware: middleware is a singleton; scoped dependencies go as `InvokeAsync` parameters (the framework resolves them per request). Constructor injection of a `DbContext` into middleware is the captive-dependency bug (DI skill) in its most common costume.
- Swallowing exceptions in middleware "to keep the pipeline alive": the exception handler above you exists for that; catch only what you can translate, rethrow the rest.
- Not calling `next()` is legitimate short-circuiting (auth, rate limiting) - but then you own writing a complete response, including status code and content type.

## The pipeline is per-request; branches are static

`app.UseWhen(ctx => ...)` / `app.Map(...)` build the branch once at startup - the predicate runs per request, the builder lambda does not. Feature-flag checks inside the builder lambda evaluate once at boot and never again; per-request toggling goes inside the middleware itself.

## Review checklist

- Every middleware between `UseRouting` and `MapX` justified - that slot is for things needing route data (CORS, auth, rate limiting, output cache).
- `app.UseDeveloperExceptionPage()` / Swagger UI inside `if (app.Environment.IsDevelopment())` - exception detail pages in production leak stack frames and connection strings (exception skill).
- Response-buffering middleware (compression, caching) declared before things that write - order determines whether they see the bytes.
- Rate limiting (`UseRateLimiter`) present on auth endpoints and anything expensive-per-call; after auth if limits are per-user, before if per-IP.
- Health checks (`MapHealthChecks`) excluded from auth, logging noise, and rate limits deliberately - and not running real dependency checks on the liveness probe (a DB blip should fail readiness, not get the pod killed).
