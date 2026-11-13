# Design

How Infusion turns an OpenAPI spec into an SDK. Draft: it follows from
[the spec survey](spec-survey.md) and from reading the official, Stainless
generated SDKs of OpenAI and Anthropic.

## Inputs

1. **The spec**: a URL or a path, JSON or YAML, OpenAPI 3.0 or 3.1.
2. **`infusion.exs`**: everything the spec doesn't say. The survey showed
   real specs leave out authentication (GitHub), pagination (all five) and
   naming, so this file is a first-class input, not an afterthought.

```elixir
# infusion.exs for the GitHub SDK
[
  module: GitHub,
  app: :github_sdk,
  spec: "https://raw.githubusercontent.com/github/rest-api-description/main/descriptions/api.github.com/api.github.com.json",

  base_url: "https://api.github.com",
  auth: [bearer: [env: "GITHUB_TOKEN"]],
  headers: [{"x-github-api-version", "2022-11-28"}],

  # Pagination styles, matched to operations by the parameters they take.
  pagination: [
    link_header: [when: [:per_page, :page]]
  ],

  # How operations become modules and functions.
  naming: [
    group_by: :tag,                                  # GitHub.Repos, GitHub.Issues
    function: {:operation_id, split: "/"},            # "repos/get" -> get
    rename: %{"repos/list-for-authenticated-user" => {GitHub.Repos, :list_mine}}
  ],

  # Fixes for mistakes in the vendor's spec, applied before generation.
  patches: []
]
```

Pagination styles found in the survey, each a declarative rule:

| Style | APIs | Rule |
|---|---|---|
| `cursor_after` | OpenAI, Stripe | send `after` / `starting_after` = last item's `id` while `has_more` |
| `cursor` | Cloudflare | send `cursor` = `result_info.cursor` |
| `page` | Cloudflare, GitHub | increment `page` until fewer than `per_page` items, or `total_pages` |
| `offset` | Cloudflare | `offset += limit` |
| `token` | Twilio | follow `meta.next_page_url` |
| `link_header` | GitHub | follow `rel="next"` in the `Link` header |

## Pipeline

```
load ──► resolve ──► normalize ──► IR ──► generate ──► format ──► write
```

  * **load**: JSON, or YAML parsed without type coercion (a YAML loader turned
    example strings in OpenAI's spec into dates). Must handle 28 MB
    (Cloudflare) in seconds.
  * **resolve**: `$ref`s, local and remote, with cycles kept as references.
  * **normalize**: 3.0 `nullable: true` and 3.1 `type: [x, "null"]` become
    one form; `allOf` is flattened into one object (Cloudflare has 3,705),
    with conflicting fields reported.
  * **IR**: the generator never reads the spec directly, only this.
  * **generate**: code from the IR, then `mix format`.

The intermediate representation:

```elixir
%Infusion.IR.Operation{
  id: "repos/get", module: GitHub.Repos, function: :get,
  method: :get, path: "/repos/{owner}/{repo}", server: "https://api.github.com",
  path_params: [...], query_params: [...], header_params: [...],
  body: %{content_type: "application/json", schema: ...} | nil,
  responses: %{200 => schema, 404 => schema},
  streaming?: false, pagination: :link_header | nil,
  deprecated?: false, doc: "..."
}

%Infusion.IR.Schema{
  name: GitHub.Repository,
  kind: :object | :union | :enum | :map | :array | :scalar,
  fields: [...], required: [...], nullable?: false,
  variants: [...], discriminator: nil | {"type", %{"x" => Mod}}
}
```

## What gets generated

```
github_sdk/
  mix.exs                      # depends on :infusion_runtime
  infusion.exs                 # the config above
  lib/github.ex                # client: config, auth, request/3 for custom calls
  lib/github/repos.ex          # one module per group, one function per operation
  lib/github/schemas/*.ex      # one struct per schema
  lib/github/error.ex
  lib/github/custom/           # hand-written code; the generator never touches it
  test/
  .infusion/manifest.json      # every generated file and its hash
```

**Generated and custom code coexist.** The official SDKs keep hand-written
code (OpenAI's and Anthropic's stream accumulators, parsers, tool runners)
next to generated code. Infusion owns only the files in its manifest: it
rewrites those on every run, refuses to overwrite one that was edited by
hand, and never touches `lib/<sdk>/custom/`. A generated module picks up a
custom one of the same name (`lib/openai/custom/responses.ex`) with `use`, so
helpers like `OpenAI.Responses.stream_text/2` live in the same module as the
generated functions.

**Functions.** Path parameters are positional; everything else is a keyword
list:

```elixir
GitHub.Repos.get("elixir-lang", "elixir")
GitHub.Repos.list_for_org("elixir-lang", per_page: 100)          # one page
GitHub.Repos.list_for_org_stream("elixir-lang") |> Enum.take(250) # all pages, lazily
OpenAI.Responses.create(model: "gpt-5.5", input: "Hi", timeout: 30_000, max_retries: 5)
GitHub.Repos.get("elixir-lang", "elixir", raw: true)              # {:ok, repo, %Response{headers: ...}}
```

Each returns `{:ok, value}` or `{:error, %GitHub.Error{}}`; a `!` variant
raises.

## Types

  * **Objects** become structs. Unknown fields from newer API versions are
    kept in `__extra__`, not dropped. Each struct records which fields were
    present, so `nil` from `null` can be told apart from a missing field.
  * **Enums** stay strings, with the known values in the typespec: an API
    adding a value must not crash an older SDK.
  * **Unions with a discriminator** decode by the tag.
  * **Unions without one** (Stripe has 2,124) decode by shape: scalar types
    first, then the object variant whose required fields all match, else the
    raw map. Stripe's expandable fields become `String.t() | %Customer{}`.
  * **Deprecated** operations and fields get `@deprecated`, so users see
    compiler warnings.

## The runtime (`infusion_runtime`)

The behaviour every SDK shares, built on Req:

  * auth (bearer, basic, API key, custom), default headers, base URL and
    server variables per operation (Twilio, Cloudflare)
  * request bodies: JSON, **nested form encoding** (Stripe's
    `metadata[key]=value`, Twilio), multipart uploads
  * retries: 2 by default on connection errors, 408, 409, 429, 5xx;
    `x-should-retry`, `retry-after-ms`, `retry-after`; backoff
    `min(0.5s * 2^n, 8s)` with up to 25% jitter; an idempotency key reused
    across retries where the API names a header
  * timeouts: 10 minutes by default, per request
  * streaming: Server-Sent Events as an Elixir `Stream`; a stream that has
    started is never retried
  * pagination: the styles above, as lazy streams
  * errors: connection, timeout, and status errors with `type`
    (`:rate_limit`, `:not_found`, ...), body, headers and request ID
  * telemetry: `[:infusion, :request, :start | :stop | :exception]`
  * testing: stub any operation with `Req.Test`

It depends only on Req, and stays small: everything API-specific belongs in
the generated SDK.
