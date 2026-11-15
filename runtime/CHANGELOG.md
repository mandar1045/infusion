# Changelog

## 0.1.1

What the Twilio SDK needs; nothing changes for existing SDKs.

  * Path parameters filled from a setting (`client_path_params` in an
    operation): Twilio's `{AccountSid}` comes from `config :twilio,
    account_sid: ...` or a call's `account_sid:` option, and a missing one
    raises an `ArgumentError` that says which setting to set
  * Settings an SDK defines itself are kept in `Infusion.Runtime.Config`'s
    `extra` and read with `Infusion.Runtime.Config.setting/2`, resolving
    `{:env, "VAR"}` and functions like the API key
  * Basic auth from two places: `api_key: {{:env, "SID"}, {:env, "TOKEN"}}`;
    if either is unset, no credential is sent

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
