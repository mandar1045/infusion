# Changelog

## 0.2.0

Names that match the official SDKs. This renames generated functions, so
regenerate SDKs made with 0.1.

  * When a spec shows the official SDK call in its examples (OpenAI's
    `x-oaiMeta`), that name is used: `OpenAI.Chat.Completions.create`, not
    `OpenAI.Chat.create_completion`
  * Otherwise operations are named by their path, the way the official SDKs
    nest resources: `Accounts.Messages.list` (Twilio), `Customers.search`
    (Stripe), `VectorStores.FileBatches.cancel` (OpenAI). Tags are only used
    when the path names no resource
  * `POST` to a singular path is `create` unless the path can also be read;
    a verb ending the path (`/graders/validate`) is an action; a path with
    items under it is a collection even when its name is singular
  * A `?beta=true` flag in a path becomes a `Beta` namespace, as in OpenAI's
    official SDK; `.json` suffixes (Twilio) are no longer part of names
  * When two operations would get the same name, the second is named after its
    operation ID without the module's words (`list_configurations`), not
    with the whole ID appended

Measured against the official OpenAI Python SDK: 83% of OpenAI's operations
now get exactly the official name (up from 13%), leaving aside the `beta.` and
`admin.` prefixes OpenAI sets outside its spec.

Also: the README no longer claims GitHub's best Elixir client is 5.7 years
old (`github_sdk` had a release in 2025), and the package README no longer
says it isn't on Hex.

## 0.1.0

First release.

  * `mix infusion.gen SPEC --name Module` writes a complete Mix project from
    an OpenAPI 3.0 or 3.1 spec, JSON or YAML, file or URL
  * `$ref` resolution, `nullable` / 3.1 type arrays normalized, `allOf`
    merged
  * A struct per schema, with real union types and forward compatibility
  * One module per resource and one function per operation (plus `!`
    variants), with docs and typespecs
  * `_stream` functions for operations that answer with Server-Sent Events
  * `_all` functions for list operations, with the pagination style worked
    out from the spec
  * Generated SDKs depend on `infusion_runtime` 0.1
  * Tested on the published specs of OpenAI, Stripe, GitHub, Twilio and
    Cloudflare: every SDK compiles without warnings
