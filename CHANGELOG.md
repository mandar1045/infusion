# Changelog

## 0.6.0

SDKs that notice when the API disagrees with its own spec, and fix
themselves.

  * Drift checking (needs `infusion_runtime` 0.2): with `config
    :infusion_runtime, drift: true`, a generated SDK compares every response
    with the spec it was generated from: undocumented fields, missing
    required fields, unexpected nulls, wrong types, unknown enum values and
    union variants. `Infusion.Runtime.Drift.export/1` writes what it saw
  * `mix infusion.drift report.json` traces each finding to the exact place
    in the vendor's spec (through renames, inline objects, `allOf` and
    `$ref`s), prints the fix, writes it to `infusion.patches.json` with
    `--write`, and drafts an issue for the API's owners with `--issue`
  * Spec patches: `patches:` in `infusion.exs`, or `infusion.patches.json`
    next to it, fix the vendor's spec as it is loaded (`merge`, `unrequire`,
    `add_enum`, and JSON Patch's `add` / `replace` / `remove`). A patch the
    spec no longer needs (the vendor fixed it) is reported so you can drop it
  * Generated structs say which fields are required and which can be null
    (`__schema__(:required)`, `__schema__(:nullable)`)
  * Fix: a field referring to a nullable schema (GitHub's
    `nullable-simple-user`, 64 such schemas in GitHub's spec) is typed
    `... | nil`; it wasn't, even though the API returns `null` there
  * Generated SDKs depend on `infusion_runtime ~> 0.2.0`
  * Any list, live: every paginated list function gets a `_watch` variant
    (`GitHub.Issues.list_for_repo_watch/4`) that starts a process sending
    `:created`, `:updated` (with the fields that changed), `:deleted` and
    `:entered` (an older item that moved into a partial view) events.
    Conditional requests make unchanged polls a `304`, which GitHub doesn't
    count against the rate limit. The item's ID field is detected from the
    schema (`id`, Twilio's `sid`, ...)
  * Fix: a named list of inline objects (CoinGecko's `CoinsMarkets`) decodes
    into structs (`CoinsMarket`) instead of plain maps; 261 more schemas get
    structs in GitHub's SDK
  * Remote procedure calls are named from the operation ID, not the path
    (#1). When a path ends in its operation's own ID (`POST /api/GetUser`
    with `GetUser`, as Lather serves SOAP services over JSON, or Slack's
    `POST /chat.postMessage`), the path names a call, not a resource: the
    function is now `Operations.get_user` (the tag and the operation ID)
    instead of `GetUser.create`. SDKs generated from such specs get new
    names when regenerated; the names in the OpenAI, Stripe, GitHub,
    Cloudflare, Twilio and Surge SDKs don't change

## 0.5.2

  * Regenerating never replaces a file Infusion didn't write: a new
    generated file at the path of a hand-written one (a resource added to
    the spec, named like your `custom/` module) stops the run and names it

## 0.5.1

  * The regeneration workflow's pull request lists new and deleted files in
    its summary of changes, not only modified ones. Found by its first run
    on the Twilio SDK

## 0.5.0

SDKs that keep themselves up to date.

  * Every generated SDK gets a GitHub workflow that, when its spec is a URL,
    fetches the spec every day, regenerates the SDK, compiles it with
    warnings as errors, runs its tests, and opens a pull request when
    anything changed. Plus a CI workflow for pushes and pull requests
  * Generated SDKs depend on `infusion` (dev only, pinned to the minor
    version), so `mix infusion.gen --config infusion.exs` works in the SDK's
    own directory, as its `infusion.exs` says
  * `.infusion/manifest.json` records every generated file and its hash.
    Regenerating deletes the files the new run doesn't generate (a schema
    renamed or dropped from the spec), and stops, naming them, when
    generated files were edited by hand (`--force` overwrites). Files
    Infusion didn't generate are never touched. The first run in an SDK made
    before 0.5 deletes nothing
  * A `CHANGELOG.md` in `keep` goes into the generated docs

## 0.4.0

Everything the first generated SDK, [Twilio](https://github.com/mandar1045/twilio),
needed. Generated SDKs now depend on `infusion_runtime` 0.1.1.

  * `path_defaults`: a path parameter filled from a client setting instead
    of an argument. Twilio's `{AccountSid}` is in every path; with
    `path_defaults: %{"AccountSid" => {:account_sid, {:env, "TWILIO_ACCOUNT_SID"}}}`
    the call is `Twilio.Messages.create(params)`, and `account_sid:` on a call
    picks another account
  * `env_var: {"TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN"}`: basic auth from
    two environment variables
  * `schema_names: :last_segment`: `api.v2010.account.message` is
    `Twilio.Schemas.Message`, when no other schema ends the same way
  * `keep: ["README.md"]`: files the SDK's author owns once they exist;
    `description` and `links` for the generated `mix.exs`
  * A `GET` of a singular path that answers a page of a list is `list`, not
    `retrieve` (`Twilio.AvailablePhoneNumbers.Local.list("US")`); a path with
    a file extension is the collection of its items
    (`/Calls/{CallSid}/Siprec.json` is `Calls.Siprec.create`). Only Twilio's
    names change among the five specs surveyed

## 0.3.0

`infusion.exs`: what the spec doesn't say, in one file next to the SDK. And
structs for the responses that were still plain maps.

  * Objects a spec writes inline in a response, a list of results, or an
    event stream are now structs named after the operation:
    `Stripe.Schemas.CustomersListResponse`,
    `GitHub.Schemas.ActionsListArtifactsForRepoResponse`, with their list
    items (`...ResponseItem`) and events (`...Event`). That is 2,132
    operations across Stripe, GitHub, Twilio, Cloudflare and OpenAI that
    returned maps before. Pages read by `_all` functions decode their items
    the same way. Regenerate SDKs to get them; code that matched on plain
    maps (`%{"data" => ...}`) needs the struct fields instead

  * `mix infusion.gen --config infusion.exs` (or no arguments, when
    `./infusion.exs` exists); command-line flags win over the file
  * `rename` an operation to `"Module.function"` and `rename_modules` a
    module with everything under it. Operations are picked by `"GET /path"`,
    operation ID, or generated name. Names that match nothing are warnings;
    two operations with one name is an error
  * Client defaults: `base_url` (for specs without servers), `auth`,
    `headers`, `timeout`, `max_retries`, `idempotency_header`, and more
  * `pagination` per operation: `false`, or a style with its parameters and
    where the items are, for lists Infusion can't work out itself
  * Every generated SDK gets an `infusion.exs` with the settings it was made
    with; regenerating from it rewrites the SDK in place and keeps the file
    as you edited it

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
