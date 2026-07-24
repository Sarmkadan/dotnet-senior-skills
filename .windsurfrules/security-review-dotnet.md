# security-review-dotnet

Security review checklist for ASP.NET Core - authorization vs authentication, IDOR, mass assignment, SQL injection through raw SQL and EF, secrets exposure, and unsafe deserialization. Use when reviewing endpoints, data access, or anything handling user input or credentials.

## Authentication is not authorization

Authentication answers "who is this"; authorization answers "may THEY do THIS to THAT resource". The standard failure: an endpoint behind `[Authorize]` that never checks the resource belongs to the caller.

- Every controller/endpoint group has an explicit auth posture. Set the fallback policy so unmarked endpoints are DENIED, and make anonymous access an explicit opt-in:

```csharp
builder.Services.AddAuthorizationBuilder()
    .SetFallbackPolicy(new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build());
```

- Role checks (`[Authorize(Roles = "Admin")]`) cover class-level access; resource-level access (this order, this document) requires a resource check in the handler - `IAuthorizationService.AuthorizeAsync(user, order, "OrderOwner")` or an ownership filter in the query itself.

## IDOR - the highest-yield finding in CRUD APIs

```csharp
// non-compiling: illustrative
// WRONG: any authenticated user reads any invoice by iterating ids
[HttpGet("{id}")]
public Task<InvoiceDto?> Get(int id) => _db.Invoices.Where(i => i.Id == id).ProjectToDto().FirstOrDefaultAsync();
// RIGHT: ownership is part of the query, absence is 404 (don't leak existence via 403)
public Task<InvoiceDto?> Get(int id) => _db.Invoices
    .Where(i => i.Id == id && i.CustomerId == _currentUser.CustomerId)
    .ProjectToDto().FirstOrDefaultAsync();
```

Review every endpoint taking an id: where is the tenancy/ownership predicate? In multi-tenant systems, prefer EF global query filters (`HasQueryFilter(e => e.TenantId == tenantProvider.TenantId)`) so a forgotten `Where` fails safe - and audit every `IgnoreQueryFilters()` call as a privileged operation. Sequential ints make IDOR trivially enumerable; that argues for GUIDs/ULIDs on exposed ids, but random ids are obscurity, not authorization - the predicate is still required.

## Mass assignment / over-posting

Binding request bodies to entities lets clients set any column: `{"name":"x","isAdmin":true,"balance":9999}`. Bind to request DTOs containing exactly the client-settable fields; map explicitly. The same applies to updates: `PATCH`/`PUT` handlers that copy all incoming properties onto the entity (`_mapper.Map(request, entity)` with a permissive profile) need a field-by-field review. Server-owned fields - id, timestamps, owner, role, state - are never bound from input.

## SQL injection

Parameterization is the only defense; EF LINQ is parameterized automatically. The dangerous surface is raw SQL:

```csharp
// non-compiling: illustrative
// WRONG: interpolation into the SQL string
var users = db.Users.FromSqlRaw($"SELECT * FROM Users WHERE Name = '{name}'");
// RIGHT: FromSql / FromSqlInterpolated turns interpolation holes into parameters
var users = db.Users.FromSql($"SELECT * FROM Users WHERE Name = {name}");
```

`FromSqlRaw`/`ExecuteSqlRaw` with string concatenation or `string.Format` is a rejection. Watch the copy-paste trap: moving an interpolated string from `FromSql` (safe) to `FromSqlRaw` (now injectable) compiles cleanly. Identifiers (table/column names, ORDER BY direction) cannot be parameterized - allowlist them against a fixed set, never pass through. Same rules for Dapper: values via anonymous-object parameters, identifiers via allowlist.

## Secrets and data exposure

- No credentials in source or config files (see configuration-and-secrets). In review, grep diffs for literal keys/tokens/passwords.
- Exception details, stack traces, and EF error messages never reach response bodies in production - global handler returns ProblemDetails with a correlation id.
- Logging: no passwords, tokens, full card numbers, or session cookies in log statements; structured-log whole-object dumps (`{@request}`) are the common leak.
- Responses: returning entities exposes columns you forgot were sensitive (password hashes, internal flags). DTO projection is a security control, not just hygiene.

## Input handling and platform hardening

- Deserialization: never `BinaryFormatter` (RCE, removed for a reason) and no `TypeNameHandling.All`/`JsonSerializerSettings` with polymorphic type names on untrusted input (gadget-chain RCE). System.Text.Json with explicit `[JsonDerivedType]` discriminators is the safe polymorphism.
- File uploads: validate extension AND content type against an allowlist, cap size, store outside the web root under server-generated names; never trust `FileName` for the path (`../` traversal).
- SSRF: any endpoint fetching a user-supplied URL needs an allowlist of hosts/schemes; block private ranges and redirects to them.
- CSRF: cookie-authenticated state-changing endpoints need antiforgery tokens; pure bearer-token APIs do not, but then `SameSite` and CORS config carry the weight - CORS with `AllowAnyOrigin` plus credentials is misconfiguration (the framework rejects the combination; wildcard-reflecting origins by hand recreates it).
- Password handling: ASP.NET Core Identity or `PasswordHasher<T>`; hand-rolled SHA256(password) is a finding regardless of salt.
