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

Pagination styles found in the survey. The generator recognises them from
each list operation's parameters and response (`Infusion.Gen.Pagination`);
`infusion.exs` will be able to override what it finds.

| Style | APIs | Recognised by | Next page |
|---|---|---|---|
| `cursor_after` | OpenAI, Stripe | `after` / `starting_after` + `has_more` | `after` = `last_id` or the last item's `id`, while `has_more` (backwards from `before` / `ending_before`) |
| `cursor` | Cloudflare, Stripe search, OpenAI usage | a string `cursor` / `page` parameter + a `cursor` / `next_page` / `next` field | send that field back |
| `next_url` | Twilio | a `next_page_uri` / `next_page_url` field | follow it (relative URLs too) |
| `page` | GitHub, Cloudflare | an integer `page` | the `Link` header when sent, else `page + 1` until a page is empty, short, or past `total_pages` |
| `offset` | Cloudflare | `offset` + `limit` | `offset += items` |
| `link_header` | GitHub | other paging parameters (`per_page`, `after`) | `rel="next"` in the `Link` header |

Measured: OpenAI 86 list operations, Stripe 133, GitHub 281, Twilio 60,
Cloudflare 328. Every style stops on an empty page, so a wrong guess costs
one extra request, never a loop.

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
  lib/github.ex                # client: defaults from the spec, config/1, request/4
  lib/github/repos.ex          # one module per group, one function per operation
  lib/github/schemas/*.ex      # one struct per schema
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

**Names** come from, in order: vendor SDK hints (Cloudflare's
`x-fern-sdk-*`), the official SDK call in the spec's examples (OpenAI's
`x-oaiMeta`), `group/action` operation IDs (GitHub), then the path, nested the
way the official SDKs nest resources. The tag is the last resort. See
`Infusion.Naming`; measured against the official OpenAI Python SDK, 83% of
operations get the official name.

**Functions.** Path parameters are positional. Query, header and body
parameters are one map or keyword list; call options come last, so a body
field named `timeout` never clashes with the `timeout:` option:

```elixir
GitHub.Repos.get("elixir-lang", "elixir")
GitHub.Repos.list_for_org("elixir-lang", per_page: 100)                  # one page
GitHub.Repos.list_for_org_all!("elixir-lang") |> Enum.take(250)           # every page, lazily
OpenAI.Chat.Completions.create(%{model: "gpt-5.5", messages: msgs}, timeout: 30_000, max_retries: 5)
GitHub.Repos.get("elixir-lang", "elixir", raw: true)                      # {:ok, %Req.Response{body: %FullRepository{}}}
```

Each returns `{:ok, value}` or `{:error, %Infusion.Runtime.Error{}}`; a `!`
variant raises. One error type for every SDK means one way to handle errors
across all of them.

The operation itself is data, kept in a module attribute next to the
function, and the runtime does the rest:

```elixir
@retrieve_operation %{
  id: "retrieveModel",
  method: :get,
  path: "/models/{model}",
  path_params: ["model"],
  params: [],                                  # [{key, wire_name, :query | :header | :body}]
  response: {:ref, OpenAI.Schemas.Model}
}

def retrieve(model, opts \\ []), do: OpenAI.__request__(@retrieve_operation, [model], %{}, opts)
```

Parameters the SDK doesn't know go into the body (or the query, for
operations without one), so a parameter the API added after the SDK was
generated can still be sent. `OpenAI.request(:get, "/new/endpoint", params)`
reaches endpoints the spec doesn't describe.

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
  * streaming: Server-Sent Events as a lazy Elixir `Stream` of decoded
    events. Operations that can stream get a `<name>_stream` function; the
    operation says how to ask for a stream (`stream_param: {"stream", true}`,
    or `{"stream_format", "sse"}` for OpenAI's speech endpoint) and how to
    decode each event (`stream_response`). Retried until the response starts,
    never after; `data: [DONE]` ends it; an error event inside the stream is
    raised. Operations that only stream return the stream from the plain
    function.
  * pagination: the styles above. A list operation gets `<name>_all`,
    returning a lazy stream of every item that fetches pages as it is read;
    the first page's error is returned, a later page's raised
  * errors: connection, timeout, and status errors with `type`
    (`:rate_limit`, `:not_found`, ...), body, headers and request ID
  * telemetry: `[:infusion, :request, :start | :stop | :exception]`
  * testing: stub any operation with `Req.Test`

It depends only on Req, and stays small: everything API-specific belongs in
the generated SDK.
