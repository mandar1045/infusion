# Changelog

## 0.2.1

Found by a soak test watching real GitHub and CoinGecko lists (3,185 open
pull requests of microsoft/vscode among them), with every list checked
against a direct fetch every 10 minutes.

  * Watchers use about 25 times less memory: one watching vscode's open pull
    requests held 320-370 MB, now about 14 MB. Items are kept as a
    fingerprint plus a compressed binary, unpacked only when they change (the
    decoded items also kept every page body alive, through strings pointing
    into it); a page that comes back `304` keeps only its item IDs; IDs and
    version values are copied out of the response
  * No more phantom deletes: pages read one after another shift when an item
    on an earlier page goes away, and an item could fall between two pages
    and be reported `:deleted` (then `:created` again). On a list of several
    pages, an item is now deleted only when two reads in a row missed it
  * An item with a creation time from before the watcher started is
    `:entered`, not `:created`, on complete lists too (reopened, or missed
    by an earlier read)

## 0.2.0

  * `Infusion.Runtime.Drift`: compares an API's responses (and stream
    events) with the spec the SDK was generated from, when turned on with
    `drift: true` (or a sample rate like `0.01`) in `config
    :infusion_runtime`, an SDK's config or a call's options. Findings are
    counted per schema, field and operation, without keeping any response
    data; `report/0`, `format/0`, `export/1` (the input of `mix
    infusion.drift`), `reset/0`, and a `[:infusion, :drift]` telemetry event
  * `Infusion.Runtime.Watch`: a list endpoint as a live feed of `:created`,
    `:updated` and `:deleted` events (with the fields that changed), sent
    to a process, a function or a `Phoenix.PubSub` topic. Every page is
    asked for with `If-None-Match`, so unchanged pages are a `304`; deletes
    only when the whole list was read; an item new to a partial view is
    `:created` only when its creation time says so, else `:entered`;
    `X-Poll-Interval` respected; `async: true` for supervision trees (an
    API that is down at boot doesn't stop the application starting);
    `ignore:` takes nested paths (`"base.repo"`) and `version:` names a
    field that alone decides whether an item changed (`"updated_at"`), both
    found needed by a soak test on GitHub, where one push "changed" all
    3,186 open vscode pull requests through their embedded repository;
    `[:infusion, :watch, :poll]` telemetry
  * The runtime now has an application (it owns the drift table)
  * `Infusion.Runtime.Schema.variant/3`: the union variant decoding picks

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
