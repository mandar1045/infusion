# Infusion

Infuse any API into Elixir: official-quality Elixir SDKs, generated from an
OpenAPI spec.

> Status: design. Nothing is published yet.

```console
$ mix infusion.gen https://raw.githubusercontent.com/openai/openai-openapi/main/openapi.yaml --name OpenAI
```

```elixir
{:ok, response} =
  OpenAI.Responses.create(model: "gpt-5.5", input: "Say hello")

# Streaming, as a plain Elixir Stream
OpenAI.Responses.stream(model: "gpt-5.5", input: "Write a haiku")
|> Stream.each(&IO.write(&1.delta))
|> Stream.run()
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

| | oapi_generator 0.4.0 | OpenAPI Generator 7.17 (elixir) |
|---|---|---|
| Reads the spec | crashes | rejects it unless forced |
| HTTP client | not generated: you write it | yes (Tesla) |
| Streaming (SSE) | no | no |
| Union types (`string` or list of parts) | reduced to `[map]` | an empty struct |

Infusion aims to close that gap: generate SDKs good enough that an API
company could ship them as their official Elixir SDK.

## What it generates

  * **One module per resource** (`Anthropic.Messages`, `GitHub.Repos`), one
    function per operation, with docs from the spec and typespecs.
  * **Structs for every schema**, decoded from responses, with **real union
    types**: a `oneOf` becomes a set of structs you can pattern match on, not
    a map or an empty struct.
  * **Streaming** for `text/event-stream` responses, as an Elixir `Stream`.
  * **Pagination** as lazy streams (`GitHub.Repos.list_stream(...)`).
  * **File uploads** (multipart), **auth** (bearer, API key, basic, OAuth
    token), **retries** with backoff on 429 and 5xx, **timeouts**.
  * **Typed errors**: `{:error, %Anthropic.Error{status: 429, type: ...}}`.
  * **Webhook signature verification** where the spec describes it.
  * **Test helpers**: stub any operation in ExUnit through `Req.Test`.
  * **Docs** that build with ExDoc, and a `mix.exs` ready to publish.

## How it's built

```
OpenAPI 3.0 / 3.1 spec (JSON or YAML, any size)
        │
        ▼
 parse + resolve $refs  ──►  intermediate representation (operations,
                             schemas, unions, pagination, auth, streaming)
        │
        ▼
 Elixir code generation  ──►  a complete, formatted Mix project
        │
        ▼
 every generated SDK depends on `infusion_runtime`
```

**`infusion_runtime`** is a small package every generated SDK depends on:
the HTTP layer (Req), auth, retries, streaming, pagination, decoding and
errors. Keeping it out of the generated code means a fix there reaches every
SDK, and generated SDKs stay small and readable. It depends only on Req, and
is meant to stay small and stable.

Specs are rarely perfect, so an `infusion.exs` file next to the spec lets you
rename modules and functions, merge or split resources, and patch the spec
where it is wrong, without editing generated code.

## Keeping SDKs current

Because SDKs are generated, staying current is a job for CI: a GitHub Action
fetches the vendor's spec on a schedule, regenerates, runs the tests, and
opens a pull request when the API changed. No hand-maintained client can keep
up like that.

## First SDKs

Popular APIs whose Elixir clients are missing or stale (Hex, November 2026),
all of which publish official OpenAPI specs:

  * **GitHub**: no maintained SDK (the best option is 5.7 years old)
  * **Cloudflare**: no SDK
  * **Twilio**: the main client hasn't been released in 2.6 years, yet gets
    122k downloads per 90 days

OpenAI is the stress test: its spec uses streaming, uploads and unions
throughout. Anthropic would be a natural target, but it no longer publishes
its spec. See [the spec survey](docs/spec-survey.md) for what these specs
demand of a generator.

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
