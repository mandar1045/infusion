# Spec survey

What real-world OpenAPI specs look like, and what that means for Infusion.
Five official specs, downloaded and measured on 2026-11-14.

| | OpenAI | Stripe | GitHub | Cloudflare | Twilio (api v2010) |
|---|---:|---:|---:|---:|---:|
| OpenAPI | 3.1.0 | 3.0.0 | 3.0.3 | 3.0.3 | 3.0.1 |
| Size | 4.3 MB (YAML) | 8.3 MB | 14.3 MB | **28.0 MB** | 1.9 MB |
| Operations | 388 | 612 | 1,281 | **3,778** | 197 |
| Schemas | 2,272 | 1,538 | 1,015 | **7,152** | 150 |
| `oneOf` / `anyOf` / `allOf` | 449 / 1,298 / 169 | 322 / **2,124** / 0 | 277 / 40 / 87 | 351 / 589 / **3,705** | 0 / 0 / 0 |
| Discriminators | 235 | **0** | 6 | 58 | 0 |
| Nullable (3.0) / type arrays (3.1) | 7 / 353 | 2,795 / 0 | 4,054 / 0 | 3,069 / 0 | 1,011 / 0 |
| Enums | 1,764 | 4,399 | 3,802 | 9,423 | 180 |
| Deprecated operations | 17 | 6 | 38 | 316 | 0 |
| Streaming (SSE) operations | 15 | 0 | 0 | 1 | 0 |
| Multipart operations | 18 | 1 | 0 | 32 | 0 |
| Request bodies | JSON | **form-encoded** (611 of 612) | JSON | JSON (+ SCIM, text) | **form-encoded** |
| Auth declared in the spec | bearer | basic, bearer | **none** | API key header, bearer | basic |
| Pagination | `after` / `before` / `limit` | `starting_after` / `ending_before` / `limit` | `page` / `per_page` + **`Link` header** (214 ops) | **mixed**: `page`/`per_page`, `cursor`, `limit`/`offset`, `pageSize` | `PageSize` / `Page` / `PageToken` |
| Servers | 1 | 1 | 1 | 1 + per path, **with variables** (`https://{stream_id}.k2...`) | per path (120) |
| Vendor extensions | `x-stainless-const`, `x-oaiMeta` | `x-expandableFields`, `x-resourceId` | `x-github`, `x-github-breaking-changes` | `x-fern-sdk-group-name`, `x-fern-sdk-method-name` | `x-twilio` |

Twilio publishes 61 separate specs, one per product; the table measures the
largest. Anthropic no longer publishes a spec: the links in its SDK's
`.stats.yml` all return 404.

## What Infusion has to handle

**Both OpenAPI 3.0 and 3.1.** Four of five specs are 3.0 (`nullable: true`),
OpenAI is 3.1 (`type: [string, "null"]`). Normalize both into one
representation early.

**Big specs, fast.** Cloudflare is 28 MB with 3,778 operations and 7,152
schemas. Parsing, `$ref` resolution and generation must be measured on it,
and YAML loading must not coerce values (a YAML loader turned example strings
in OpenAI's spec into dates).

**Unions without discriminators.** Stripe has 2,124 `anyOf` and not one
discriminator: its expandable fields are "an ID string, or the expanded
object" (`customer: "cus_123"` vs `customer: %Customer{}`). Infusion must
resolve unions by shape, not only by a tag.

**`allOf` composition.** Cloudflare uses 3,705 `allOf`: schemas built by
merging others. They have to be flattened into one struct, with conflicts
detected.

**Form-encoded bodies.** Stripe and Twilio send `application/x-www-form-urlencoded`,
Stripe with nested bracket notation (`metadata[order_id]=6735`). The runtime
needs a correct nested form encoder, not just JSON.

**Auth is not always in the spec.** GitHub declares no security schemes at
all. Auth has to be configurable outside the spec.

**Pagination is not in the spec.** Five APIs, at least six styles: cursors
named three different ways, page numbers, offsets, tokens, and GitHub's
`Link` header. Cloudflare alone mixes four. Pagination is declared per API
(and per operation where needed) in `infusion.exs`.

**Per-path and templated servers.** Twilio sets a host on each path;
Cloudflare has hosts with variables. The generated code must pick the right
base URL per operation and fill in server variables.

**Deprecations.** Cloudflare marks 316 operations deprecated. Generate them
with `@deprecated`, so users get compiler warnings.

**Vendor naming hints.** Cloudflare's `x-fern-sdk-group-name` and
`x-fern-sdk-method-name` (and Stainless hints in OpenAI's spec) say how the
vendor's own SDKs name things. Reading them gives SDKs that match the
official ones.
