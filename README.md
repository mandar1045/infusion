# Infusion

Infuse any API into Elixir: official-quality Elixir SDKs, generated from an
OpenAPI spec.

> **Status: early.** Nothing is on Hex yet. Infusion already generates
> complete SDKs for OpenAI, Stripe, GitHub, Twilio and Cloudflare that
> compile without a single warning, and the generated GitHub SDK makes live
> API calls. Streaming and pagination are next.

```console
$ mix infusion.gen https://raw.githubusercontent.com/openai/openai-openapi/main/openapi.yaml --name OpenAI
Generated OpenAI in openai_sdk/: 388 operations, 2272 schemas, 2754 files (5828 ms)
```

```elixir
{:ok, completion} =
  OpenAI.Chat.create_completion(
    model: "gpt-5.5",
    messages: [%{role: "user", content: "Say hello"}]
  )

[%{message: %{content: text}}] = completion.choices

# Typed structs in, typed errors out
case GitHub.Repos.get("elixir-lang", "elixir") do
  {:ok, %GitHub.Schemas.FullRepository{stargazers_count: stars}} -> stars
  {:error, %Infusion.Runtime.Error{type: :not_found}} -> nil
end
```

## Why

Most API companies no longer write their SDKs by hand. They generate them
with Stainless, Fern or Speakeasy, and none of those support Elixir. So when
a new API ships, Python, TypeScript, Go and Java developers get an official
SDK on day one, and Elixir developers get nothing, or a community client
that falls behind.

The open-source generators that do target Elixir don't produce SDKs you can
use for a modern API. Measured on OpenAI's published spec (OpenAPI 3.1, 388
operations, 2,272 schemas):

| | oapi_generator 0.4.0 | OpenAPI Generator 7.17 (elixir) | Infusion |
|---|---|---|---|
| Reads the spec | crashes | rejects it unless forced | yes, in about 6 s |
| HTTP client | not generated: you write it | yes (Tesla) | yes (Req), with retries |
| Union types (`string` or list of parts) | reduced to `[map]` | an empty struct | real unions, decoded |
| Compiler warnings | n/a | n/a | 0 |
| Streaming (SSE) | no | no | next |

The goal: SDKs good enough that an API company could ship them as its
official Elixir SDK.

## Measured on five real specs

Every SDK below is generated from the vendor's own published spec and
compiles with zero warnings, checked by the test suite.

| API | Operations | Modules | Generated in | Compiled in |
|---|---:|---:|---:|---:|
| OpenAI | 388 | 2,750 | 4 s | 3 min |
| Stripe | 612 | 1,771 | 3 s | 1.6 min |
| GitHub | 1,281 | 3,054 | 9 s | 2.6 min |
| Twilio | 197 | 239 | 0.5 s | 7 s |
| Cloudflare | 3,778 | 10,253 | 13 s | 3.7 min |

Between them these specs cover OpenAPI 3.0 and 3.1, a 28 MB spec,
thousands of `allOf`/`anyOf`/`oneOf`, form-encoded bodies, multipart
uploads, per-operation servers and server variables. See
[the spec survey](docs/spec-survey.md).

## Try it

Infusion isn't on Hex yet, so run it from a checkout:

```console
$ git clone https://github.com/mandar1045/infusion && cd infusion
$ mix deps.get
$ mix infusion.gen path/or/url/to/openapi.json --name GitHub --runtime-path runtime
$ cd github_sdk && mix deps.get && mix compile
```

| Option | Default | |
|---|---|---|
| `--name` | required | the base module, e.g. `OpenAI` |
| `--out` | `<name>_sdk` | where the project is written |
| `--app` | `<name>_sdk` | the OTP app name |
| `--version` | `0.1.0` | the SDK's version |
| `--env-var` | `<NAME>_API_KEY` | where the API key is read from |
| `--runtime-path` | | depend on a local `infusion_runtime` (needed until it's on Hex) |

Anything in the spec Infusion can't represent is listed in
`infusion_warnings.txt` instead of turning into broken code.

## Using a generated SDK

Path parameters are positional. Everything else the API takes is one map or
keyword list, and options for the call come last:

```elixir
OpenAI.Models.retrieve("gpt-5.5")
OpenAI.Files.list(purpose: "batch", limit: 10)
OpenAI.Chat.create_completion(%{model: "gpt-5.5", messages: msgs}, timeout: 30_000)

OpenAI.Models.retrieve!("gpt-5.5")                     # raises Infusion.Runtime.Error
OpenAI.Models.retrieve("gpt-5.5", raw: true)           # {:ok, %Req.Response{}}, for headers
OpenAI.request(:get, "/brand/new/endpoint", %{x: 1})   # anything the spec doesn't describe yet
```

Responses decode into structs. Fields the API added after the SDK was
generated land in `__extra__` instead of disappearing, and parameters the SDK
doesn't know about are still sent.

**Configuration** comes from the spec, then your config, then the call:

```elixir
# config/runtime.exs
config :openai_sdk, api_key: System.fetch_env!("OPENAI_API_KEY"), max_retries: 5

# GitHub's spec declares no auth, so say how to send the token
config :github_sdk, auth: :bearer, api_key: {:env, "GITHUB_TOKEN"}
```

**Errors** are one struct for every SDK, so you handle them the same way
everywhere:

```elixir
{:error, %Infusion.Runtime.Error{type: :rate_limit, status: 429, request_id: "req_..."}}
```

`type` is one of `:bad_request`, `:authentication`, `:permission_denied`,
`:not_found`, `:conflict`, `:unprocessable_entity`, `:rate_limit`,
`:internal_server`, `:api_error`, `:timeout` or `:connection`.

**Retries** work like the official SDKs: 2 retries on connection errors,
timeouts, 408, 409, 429 and 5xx, honouring `retry-after-ms`, `retry-after`
and `x-should-retry`, with capped exponential backoff and jitter. If the API
names an idempotency header, the key stays the same across retries.

**Testing**: point the SDK at a `Req.Test` stub.

```elixir
# config/test.exs
config :openai_sdk, req_options: [plug: {Req.Test, OpenAI}]

# in a test
Req.Test.stub(OpenAI, &Req.Test.json(&1, %{"id" => "gpt-5.5", "object" => "model"}))
{:ok, %OpenAI.Schemas.Model{id: "gpt-5.5"}} = OpenAI.Models.retrieve("gpt-5.5")
```

**Telemetry**: `[:infusion, :request, :start | :stop | :exception]`.

## How it's built

```
OpenAPI 3.0 / 3.1 spec (JSON or YAML, any size)
        │
        ▼
 load ─► resolve $refs ─► normalize ─► intermediate representation
                                      (operations, schemas, unions, auth)
        │
        ▼
 Elixir code generation ─► a complete, formatted Mix project
        │
        ▼
 every generated SDK depends on `infusion_runtime`
```

**`infusion_runtime`** is the small package every generated SDK depends on:
HTTP (Req), auth, retries, encoding, decoding and errors. Keeping it out of
the generated code means a fix there reaches every SDK, and generated code
stays short and readable: each operation is a few lines of data plus a
function that hands it to the runtime. More in [the design](docs/design.md).

## Roadmap

  * [x] OpenAPI 3.0 and 3.1, JSON and YAML, specs of any size
  * [x] Structs for every schema, real union types, forward compatible
  * [x] One function per operation, with docs and typespecs
  * [x] Runtime: auth, JSON / form / multipart bodies, retries, typed errors, telemetry
  * [x] `mix infusion.gen` writes a complete Mix project
  * [ ] Streaming (`text/event-stream`) as an Elixir `Stream`
  * [ ] Pagination as lazy streams (cursor, page, offset, `Link` header)
  * [ ] `infusion.exs`: rename modules and functions, declare pagination,
        patch the spec where it's wrong
  * [ ] Hand-written code that survives regeneration
  * [ ] A GitHub Action that regenerates an SDK when the vendor's spec
        changes and opens a pull request
  * [ ] Publish `infusion`, `infusion_runtime` and the first SDKs on Hex

## First SDKs

Popular APIs whose Elixir clients are missing or stale (Hex, November 2026),
all of which publish official OpenAPI specs:

  * **GitHub**: no maintained SDK (the best option is 5.7 years old)
  * **Cloudflare**: no SDK
  * **Twilio**: the main client hasn't been released in 2.6 years, yet gets
    122k downloads per 90 days

OpenAI is the stress test: its spec uses streaming, uploads and unions
throughout. Anthropic would be a natural target, but it no longer publishes
its spec.

## Development

```console
$ mix test                                  # generator
$ cd runtime && mix test                    # runtime
$ INFUSION_SPECS=path/to/specs mix test     # also generates and compiles the five real SDKs (~12 min)
```

## Prior art

  * [oapi_generator](https://github.com/aj-foster/open-api-generator):
    a configurable Elixir generator for typed modules, without a runtime.
  * [OpenAPI Generator](https://openapi-generator.tech): many languages,
    including an Elixir target on Tesla.
  * [Stainless](https://www.stainless.com), [Fern](https://buildwithfern.com)
    and [Speakeasy](https://www.speakeasy.com): commercial generators behind
    many official SDKs. No Elixir support.

## License

Apache 2.0
