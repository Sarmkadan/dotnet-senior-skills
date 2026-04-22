---
name: configuration-and-secrets
description: Review .NET configuration handling - options pattern, validation at startup, secret storage, environment layering, and what must never be committed. Use when touching appsettings, IConfiguration, IOptions, or anything credential-shaped.
---

# Configuration and Secrets

## Secrets: the hard rules

- No secret in `appsettings*.json`, code, or anything git-tracked. Ever. A secret that touched a commit is compromised - rotate it; deleting the commit does not un-leak it.
- Local development: `dotnet user-secrets` (lives outside the repo) or environment variables. `appsettings.Development.json` is committed in most repos - it is NOT a secrets file.
- Production: a real secret store - Azure Key Vault / AWS Secrets Manager / Vault - loaded as a configuration provider, or platform-injected environment variables. Prefer the store: env vars appear in `docker inspect`, crash dumps, and diagnostic endpoints.
- Connection strings are secrets when they contain passwords. Prefer managed identity / IAM auth (`Authentication=Active Directory Default`) so the connection string stops being one.
- Review flag: any string named or shaped like `key`, `token`, `password`, `secret` assigned a literal. Also `DefaultAzureCredential` bypasses like raw account keys "temporarily".

## Options pattern, done properly

Inject `IOptions<T>` (or a snapshot), never `IConfiguration`, into services. `IConfiguration` in a constructor means stringly-typed access (`config["Smtp:Port"]`) scattered anywhere, untypeable, untestable, unvalidatable.

```csharp
public sealed class SmtpOptions
{
    public const string Section = "Smtp";
    [Required] public required string Host { get; init; }
    [Range(1, 65535)] public int Port { get; init; } = 587;
}
services.AddOptions<SmtpOptions>()
    .BindConfiguration(SmtpOptions.Section)
    .ValidateDataAnnotations()
    .Validate(o => !o.Host.Contains(' '), "Host must not contain spaces")
    .ValidateOnStart();
```

`ValidateOnStart()` is the point: a typo'd section name otherwise yields default-valued options that fail at 3 a.m. on first use instead of at deploy. Every options class gets it.

Lifetime semantics - pick deliberately:
- `IOptions<T>`: singleton, frozen at first resolve. Default choice.
- `IOptionsSnapshot<T>`: scoped, re-reads per request - only when hot-reload of that setting is a real requirement.
- `IOptionsMonitor<T>`: for singletons needing current values or change callbacks. `OnChange` fires on the config provider's thread and can fire multiple times per file save - handlers must be idempotent and fast.

## Layering and environments

Provider order (later wins): appsettings.json -> appsettings.{Environment}.json -> user secrets (Dev) -> environment variables -> command line. Consequences:
- Environment variables override JSON: `Smtp__Port=2525` (double underscore = section separator) beats the file. This is the deploy-time override mechanism; do not invent a custom one.
- `appsettings.Production.json` should contain only structural differences (log levels, feature toggles), not secrets and not full duplication of the base file - duplicated keys drift.
- Do not branch on environment name in code (`if (env.IsProduction())`) for behavior that is really a config value; add the config value. Environment checks are for infrastructure wiring (developer exception page, Swagger) only.

## Review checklist

- `IConfiguration` injected outside Program.cs/composition root: refactor to options.
- `config.GetValue<string>("X")` result used without null handling: a missing key returns null, not an exception.
- Options classes with settable mutable state shared as singleton: use `init` setters; config objects are not scratch space.
- Feature flags: a bool in options is fine until it needs per-user targeting or runtime toggling - then a feature-management library, not a hand-rolled cache over the database.
- Startup reads of config into statics (`static readonly string ApiUrl = Config...`): breaks layering, testing, and reload; keep config access inside the options system.
- Kubernetes/containers: config via env vars or mounted files is fine, but check that secrets are `Secret` mounts, not `ConfigMap`s, and not baked into the image (`docker history` shows ENV layers).
