---
name: configuration-and-secrets
description: Review .NET configuration handling - IOptions<T> vs raw IConfiguration access, secret material never in appsettings committed to git, user-secrets/env/KeyVault ordering, and redaction in logging.
---

# Configuration and Secrets

## Secrets: the hard rules (threshold: reject on sight)

- **No secret in `appsettings*.json`, code, or anything git-tracked.** Ever. A secret that touched a commit is compromised - rotate it; deleting the commit does not un-leak it.
- **Local development:** `dotnet user-secrets` (lives outside the repo) or environment variables. `appsettings.Development.json` is committed in most repos - it is NOT a secrets file.
- **Production:** a real secret store - Azure Key Vault / AWS Secrets Manager / Vault - loaded as a configuration provider, or platform-injected environment variables. Prefer the store: env vars appear in `docker inspect`, crash dumps, and diagnostic endpoints.
- **Connection strings are secrets** when they contain passwords. Prefer managed identity / IAM auth (`Authentication=Active Directory Default`) so the connection string stops being one.
- **Review flag:** any string named or shaped like `key`, `token`, `password`, `secret` assigned a literal. Also `DefaultAzureCredential` bypasses like raw account keys "temporarily".

### Before/After: hardcoded secrets

```csharp
// non-compiling: illustrative
// WRONG: secret in committed code
public class DatabaseService
{
    private readonly string _connectionString = "Server=prod;Database=app;User Id=admin;Password=SuperSecret123!";
    
    public DatabaseService()
    {
        // This connection string is now in git history forever
    }
}

// RIGHT: use configuration with proper secret storage
public sealed class DatabaseOptions
{
    public const string Section = "Database";
    public string ConnectionString { get; init; } = string.Empty;
}

// In Program.cs:
builder.Services.Configure<DatabaseOptions>(builder.Configuration.GetSection(DatabaseOptions.Section));
```

Threshold: any literal string containing `password=`, `secret=`, `token=`, or similar credential patterns in source control is a rejection.

---

## Options pattern, done properly (threshold: reject if IConfiguration injected outside composition root)

Inject `IOptions<T>` (or a snapshot), never `IConfiguration`, into services. `IConfiguration` in a constructor means stringly-typed access (`config["Smtp:Port"]`) scattered anywhere, untypeable, untestable, unvalidatable.

### Before/After: IConfiguration vs IOptions<T>

```csharp
// non-compiling: illustrative
// WRONG: stringly-typed configuration scattered throughout codebase
public class EmailService
{
    private readonly IConfiguration _config;
    
    public EmailService(IConfiguration config)
    {
        _config = config;
    }
    
    public void SendWelcomeEmail(string userId)
    {
        var host = _config["Smtp:Host"]; // What if key is missing? Returns null
        var port = _config.GetValue<int>("Smtp:Port"); // Silent 0 on missing key
        var apiKey = _config.GetValue<string>("Email:ApiKey"); // Where is this defined?
        
        // This pattern spreads like mold - no compile-time safety, no validation
    }
}

// RIGHT: strongly-typed options with validation
public sealed class SmtpOptions
{
    public const string Section = "Smtp";
    
    [Required]
    public required string Host { get; init; }
    
    [Range(1, 65535)]
    public int Port { get; init; } = 587;
    
    [Required]
    public required string ApiKey { get; init; }
}

// Composition root (Program.cs)
services.AddOptions<SmtpOptions>()
    .BindConfiguration(SmtpOptions.Section)
    .ValidateDataAnnotations() // Validates [Required], [Range], etc.
    .ValidateOnStart(); // Fails fast at deploy, not at 3 AM
```

Threshold: `IConfiguration` injected into any service class outside Program.cs is a rejection. Only the composition root should depend on `IConfiguration`.

---

## Lifetime semantics: choose deliberately (threshold: reject captive dependencies)

- **`IOptions<T>`**: singleton, frozen at first resolve. Default choice.
- **`IOptionsSnapshot<T>`**: scoped, re-reads per request - only when hot-reload of that setting is a real requirement.
- **`IOptionsMonitor<T>`**: for singletons needing current values or change callbacks. `OnChange` fires on the config provider's thread and can fire multiple times per file save - handlers must be idempotent and fast.

### Before/After: captive dependency in singleton

```csharp
// non-compiling: illustrative
// WRONG: Scoped service captured in singleton
public sealed class CacheService : BackgroundService
{
    private readonly IOptionsSnapshot<CacheOptions> _options;
    private readonly MemoryCache _cache = new();
    
    public CacheService(IOptionsSnapshot<CacheOptions> options)
    {
        _options = options; // Captures first scope's IOptionsSnapshot
    }
    
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            // Uses stale options from first scope
            var cacheDuration = _options.Value.Duration;
            await Task.Delay(TimeSpan.FromMinutes(cacheDuration), stoppingToken);
        }
    }
}

// RIGHT: Use IOptions<T> for singleton services
services.AddSingleton<CacheService>();
services.AddOptions<CacheOptions>()
    .BindConfiguration(CacheOptions.Section)
    .ValidateOnStart();

public sealed class CacheService : BackgroundService
{
    private readonly IOptions<CacheOptions> _options; // Singleton-safe
    private readonly MemoryCache _cache = new();
    
    public CacheService(IOptions<CacheOptions> options)
    {
        _options = options;
    }
    
    // ...
}
```

Threshold: `IOptionsSnapshot<T>` injected into a singleton service is a rejection - it creates a captive dependency.

---

## Validation at startup (threshold: reject if missing)

`ValidateOnStart()` is the point: a typo'd section name otherwise yields default-valued options that fail at 3 a.m. on first use instead of at deploy. Every options class gets it.

### Before/After: missing validation

```csharp
// non-compiling: illustrative
// WRONG: No validation - typos go unnoticed until production
services.AddOptions<SmtpOptions>()
    .BindConfiguration(SmtpOptions.Section); // Missing ValidateOnStart()

// RIGHT: Validate at startup
services.AddOptions<SmtpOptions>()
    .BindConfiguration(SmtpOptions.Section)
    .ValidateDataAnnotations()
    .ValidateOnStart(); // Fails fast: "Section 'Smtp' not found"
```

Threshold: Any `IOptions<T>` registration without `.ValidateOnStart()` is a rejection.

---

## Layering and environments (threshold: reject custom override mechanisms)

Provider order (later wins): appsettings.json -> appsettings.{Environment}.json -> user secrets (Dev) -> environment variables -> command line.

### Before/After: environment variable overrides

```bash
# WRONG: Custom override mechanism reinvented
# Instead of using standard env var: SMTP__PORT=2525
services.Configure<SmtpOptions>(options => 
    options.Port = int.Parse(Environment.GetEnvironmentVariable("SMTP_PORT_OVERRIDE") ?? "587"));

# RIGHT: Use standard double-underscore notation
# SMTP__PORT=2525 in environment automatically overrides appsettings.json
```

Consequences:
- Environment variables override JSON: `Smtp__Port=2525` (double underscore = section separator) beats the file. This is the deploy-time override mechanism; do not invent a custom one.
- `appsettings.Production.json` should contain only structural differences (log levels, feature toggles), not secrets and not full duplication of the base file - duplicated keys drift.
- Do not branch on environment name in code (`if (env.IsProduction())`) for behavior that is really a config value; add the config value. Environment checks are for infrastructure wiring (developer exception page, Swagger) only.

Threshold: Any custom configuration override mechanism (hardcoded environment variable names, custom parsing) is a rejection.

---

## Redaction in logging (ties into logging skill)

Never log configuration values, especially secrets. Use structured logging with redaction or exclude sensitive fields entirely.

### Before/After: logging sensitive configuration

```csharp
// non-compiling: illustrative
// WRONG: Logging configuration including secrets
var connectionString = builder.Configuration.GetConnectionString("Default");
_logger.LogInformation("Connecting to {ConnectionString}", connectionString); // Secret in logs!

// RIGHT: Never log connection strings or sensitive values
_logger.LogInformation("Connecting to database"); // No sensitive data
```

Threshold: Any log statement that includes configuration values containing `password`, `secret`, `key`, or `token` is a rejection.

---

## Review checklist

- **Secrets in git:** Any `.git-tracked` file containing secrets, or secrets committed to git history (even if later removed) is a rejection.
- **IConfiguration injected outside Program.cs:** Refactor to strongly-typed options.
- **Missing validation:** Any `IOptions<T>` registration without `.ValidateOnStart()` is a rejection.
- **Stringly-typed access:** `config["X"]` or `config.GetValue<string>("X")` in service constructors is a rejection.
- **Captive dependencies:** `IOptionsSnapshot<T>` injected into singleton services is a rejection.
- **Custom override mechanisms:** Reinventing environment variable parsing instead of using standard double-underscore notation is a rejection.
- **Logging sensitive values:** Any log statement that includes configuration values with `password`, `secret`, `key`, or `token` patterns is a rejection.
- **Connection strings with passwords:** Prefer managed identity / IAM auth to eliminate password from connection strings.
- **Production secrets in appsettings.Production.json:** All secrets must come from secret stores or environment variables, never committed files.
- **Feature flags as bools:** A bool in options is fine until it needs per-user targeting or runtime toggling - then a feature-management library, not a hand-rolled cache.