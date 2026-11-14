# Changelog

## 0.1.0

First release.

  * Requests built from generated operations: path, query and header
    parameters, JSON, nested form and multipart bodies, auth (bearer, basic,
    API key header or query)
  * Retries on connection errors, timeouts, 408, 409, 429 and 5xx, honouring
    `retry-after-ms`, `retry-after` and `x-should-retry`, with capped
    exponential backoff and jitter; idempotency keys reused across retries
  * `Infusion.Runtime.Error` with a `type` per status, the body, headers and
    request ID; GitHub's 403 with no rate limit left is `:rate_limit`
  * Decoding into generated structs: unions by discriminator or by shape,
    unknown fields kept, `null` told apart from missing
  * Server-Sent Events as a lazy `Stream` (`Infusion.Runtime.SSE`,
    `Infusion.Runtime.Request.stream/5`)
  * Pagination as a lazy `Stream` of items (`Infusion.Runtime.Paginate`)
  * Telemetry events `[:infusion, :request, :start | :stop | :exception]`
