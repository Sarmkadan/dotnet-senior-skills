# logging-and-observability

Review .NET logging and observability - structured logging discipline, log levels, what not to log, correlation, exception logging, and metrics/tracing hooks. Use when reviewing ILogger usage, log statements, or diagnostics code.

## Structured logging, or it did not happen

Message templates with named placeholders, never interpolation:

```csharp
// non-compiling: illustrative
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

### Secrets redaction rules

Never log full DTOs/entities via structured logging destructuring (`{@Entity}`) without explicit redaction. Always use:
- `[JsonIgnore]` or `[LogPropertyIgnore]` attributes on sensitive properties
- Explicit allowlists of safe properties
- Source-generated logger with property filtering
- Manual redaction before logging

#### Never log raw DTOs with secrets

```csharp
// non-compiling: illustrative

// WRONG: Logging full request DTO exposes API keys, passwords, tokens
public record CreateUserRequest(string Username, string Password, string ApiKey);

public class UserController : ControllerBase
{
    private readonly ILogger<UserController> _logger;

    public UserController(ILogger<UserController> logger)
    {
        _logger = logger;
    }

    [HttpPost("register")]
    public IActionResult Register(CreateUserRequest request)
    {
        // Secret data logged: Password and ApiKey appear in logs
        _logger.LogInformation("Creating user {@Request}", request);

        // ... create user ...
        return Ok();
    }
}

// RIGHT: Never log the raw DTO - extract only safe fields
[HttpPost("register")]
public IActionResult Register(CreateUserRequest request)
{
    // Log only non-sensitive fields
    _logger.LogInformation("Creating user {Username}", request.Username);

    // Or create a DTO without secrets for logging
    _logger.LogInformation("Creating user {Username} from {IpAddress}",
        request.Username,
        HttpContext.Connection.RemoteIpAddress);

    // ... create user ...
    return Ok();
}
```

#### Never log raw exceptions from data-access code

```csharp
// non-compiling: illustrative

// WRONG: Exception.ToString() includes connection strings in message
public class UserRepository
{
    private readonly ILogger<UserRepository> _logger;
    private readonly string _connectionString;

    public UserRepository(ILogger<UserRepository> logger, string connectionString)
    {
        _logger = logger;
        _connectionString = connectionString;
    }

    public User GetById(int id)
    {
        try
        {
            // ... database access ...
        }
        catch (Exception ex)
        {
            // Exception.ToString() includes connection string!
            _logger.LogError(ex, "Failed to get user {UserId}", id);
            throw;
        }
    }
}

// RIGHT: Never log raw exception from data layer - sanitize first
public class UserRepository
{
    private readonly ILogger<UserRepository> _logger;

    public UserRepository(ILogger<UserRepository> logger)
    {
        _logger = logger;
    }

    public User GetById(int id)
    {
        try
        {
            // ... database access ...
        }
        catch (Exception ex)
        {
            // Log sanitized message without connection string
            _logger.LogError(ex, "Failed to get user {UserId}", id);
            throw;
        }
    }
}

// Alternative: Use exception filters or sanitize exception
public static class ExceptionSanitizer
{
    public static string Sanitize(Exception ex)
    {
        // Remove connection strings from exception messages
        return ex.Message.Replace("Password=", "Password=***")
                       .Replace("User Id=", "User Id=***");
    }
}
```

#### Use attributes for automatic redaction

```csharp
// non-compiling: illustrative

// Mark sensitive properties with [JsonIgnore] or [LogPropertyIgnore]
public record UserCredentials(
    string Username,
    [property: JsonIgnore] string Password,  // Never logged
    [property: JsonIgnore] string ApiKey);   // Never logged

public class AuthService
{
    private readonly ILogger<AuthService> _logger;

    public AuthService(ILogger<AuthService> logger)
    {
        _logger = logger;
    }

    public void Authenticate(UserCredentials credentials)
    {
        // Safe: Password and ApiKey are ignored
        _logger.LogInformation("Authenticating user {Username}", credentials.Username);
    }
}
```

#### Use source-generated loggers with property filtering

```csharp
// non-compiling: illustrative

// Define source-generated logger with safe properties
[LoggerMessage(1, LogLevel.Information, "Processing user {Username}")]
public static partial void ProcessingUser(
    ILogger logger,
    string username);

public class UserProcessor
{
    private readonly ILogger<UserProcessor> _logger;

    public UserProcessor(ILogger<UserProcessor> logger)
    {
        _logger = logger;
    }

    public void Process(User user)
    {
        // Only Username is logged, other properties ignored
        ProcessingUser(_logger, user.Username);
    }
}
```

## Correlation and scope

- One correlation id per request, propagated to outbound calls (`traceparent` header - ASP.NET Core + HttpClient do this automatically once OpenTelemetry or Activity propagation is on). A log line that cannot be joined to its request is decoration.
- `ILogger.BeginScope` attaches ambient fields (`OrderId`, `TenantId`) to every log inside the block - use it at operation entry instead of repeating the id in every template.
- Background jobs: request correlation dies at the queue boundary unless you carry it - store the trace context in the message envelope and restore it in the consumer.

## Hot paths and source generators

Per-call `params object[]` allocation is real in tight loops: use `[LoggerMessage]` source-generated logging for hot-path log sites (zero-allocation, compile-checked templates). Guard expensive value computation with `if (_logger.IsEnabled(LogLevel.Debug))` - the guard is free; building a debug dump string that gets filtered is not.

## Metrics vs logs

A counter incremented per event you would otherwise grep-and-count (`orders_placed_total`, `cache_misses`) belongs in `System.Diagnostics.Metrics.Meter`, not in log volume. Review flag: dashboards built by parsing log messages - that is a metric with extra steps and a fragile regex.
