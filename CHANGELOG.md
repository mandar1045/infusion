# Changelog

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
