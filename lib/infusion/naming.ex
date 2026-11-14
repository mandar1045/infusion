defmodule Infusion.Naming do
  @moduledoc """
  Turns OpenAPI names into Elixir module and function names.

  Each operation gets a module path (`["Repos"]`, `["ZeroTrust", "Devices"]`)
  and a function name, from the first strategy that applies:

    1. **Vendor SDK hints**: `x-fern-sdk-group-name` (dot-separated groups)
       and `x-fern-sdk-method-name`. Cloudflare sets them on nearly every
       operation, so its SDK matches the official ones.
    2. **The official SDK call in the spec's examples**: OpenAI's
       `x-oaiMeta` examples show `client.beta.assistants.list(...)`, which
       becomes `Beta.Assistants.list`.
    3. **`group/action` operation IDs**, as GitHub uses (`repos/get`).
    4. **The path**, the way the official SDKs nest resources: `GET
       /v1/customers` is `Customers.list`, `POST /v1/customers/{id}` is
       `Customers.update`, `POST /v1/payment_intents/{id}/cancel` is
       `PaymentIntents.cancel`, and `/v1/customers/{id}/sources` is a nested
       `Customers.Sources`.
    5. **The tag and the operation ID**, when the path has no resource in it
       (`/` or `/{id}`), with version prefixes taken off the tag (Twilio's
       `Api20100401Recording`) and the module's words taken off the function.
  """

  @type operation_name :: %{module: [String.t()], function: String.t(), strategy: atom}

  @doc """
  Names an operation. `op` is the operation object, `path` and `method` its
  location. `context` can say more about the API:

    * `methods:` every method `path` supports: a `POST` to a path that can
      also be read is an update, otherwise a create
    * `collections:` the paths that have items under them (`/things/{id}`),
      so `/organization/external_storage` is a collection although its name
      is singular
  """
  @spec operation(map, String.t(), String.t(), keyword) :: operation_name
  def operation(op, path, method, context \\ []) do
    cond do
      is_binary(op["x-fern-sdk-group-name"]) and is_binary(op["x-fern-sdk-method-name"]) ->
        %{
          module: op["x-fern-sdk-group-name"] |> String.split(".") |> Enum.map(&module_part/1),
          function: function_name(op["x-fern-sdk-method-name"]),
          strategy: :vendor_hint
        }

      call = example_call(op) ->
        {module, function} = call
        # The example for OpenAI's `/responses?beta=true` leaves out `beta`.
        module = Enum.reject(namespace(path), &(&1 in module)) ++ module

        %{
          module: Enum.map(module, &module_part/1),
          function: function,
          strategy: :official_example
        }

      is_binary(op["operationId"]) and String.contains?(op["operationId"], "/") ->
        [group | rest] = String.split(op["operationId"], "/")

        %{
          module: [module_part(group)],
          function: function_name(Enum.join(rest, "_")),
          strategy: :grouped_id
        }

      name = rest_name(path, method, context) ->
        name

      true ->
        module = (tag(op) || "Default") |> strip_version_prefix() |> module_part()

        function =
          op["operationId"]
          |> Kernel.||("#{method}_#{path}")
          |> function_name()
          |> drop_module_words(module)

        %{module: [module], function: function, strategy: :tag}
    end
  end

  # The SDK call shown in OpenAI's x-oaiMeta examples, Python first:
  # `client.beta.assistants.list(` or
  # `openai.audio.speech.with_streaming_response.create(`.
  @example_call ~r/\b(?:client|openai)\.((?:[a-z_][a-z0-9_]*\.)+[a-z_][a-z0-9_]*)\(/
  @response_wrappers ~w(with_streaming_response with_raw_response)

  defp example_call(%{"x-oaiMeta" => %{"examples" => examples}}) do
    code =
      for example <- List.wrap(examples),
          is_map(example),
          request = example["request"],
          is_map(request),
          lang <- ["python", "javascript", "node.js"],
          is_binary(request[lang]),
          do: request[lang]

    Enum.find_value(code, fn source ->
      # The last call is the one being shown: examples often list first to
      # get an ID (`list()`, then `retrieve(completion_id)`).
      with [_ | _] = calls <- Regex.scan(@example_call, source, capture: :all_but_first),
           [call] = List.last(calls),
           parts = call |> String.split(".") |> Enum.reject(&(&1 in @response_wrappers)),
           [_ | [_ | _]] <- parts do
        {Enum.drop(parts, -1), function_name(List.last(parts))}
      else
        _ -> nil
      end
    end)
  end

  defp example_call(_op), do: nil

  defp tag(%{"tags" => [tag | _]}) when is_binary(tag) and tag != "", do: tag
  defp tag(_), do: nil

  ## Path-based (REST) naming

  @doc false
  # nil when the path has no resource to name (`/`, `/{id}`).
  def rest_name(path, method, context \\ []) do
    methods = Keyword.get(context, :methods, [])
    collections = Keyword.get(context, :collections, MapSet.new())
    collection? = MapSet.member?(collections, path_only(path))
    # A named member of a collection: `/v1/customers/search` next to
    # `/v1/customers/{id}`, or Wikimedia's `/v2/stream/mediawiki.recentchange`
    # next to `/v2/stream/{streams}`.
    parent = path |> path_only() |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
    member? = MapSet.member?(collections, parent)
    # ...unless it supports several methods: then it's a collection of its own
    # (Twilio's `IncomingPhoneNumbers/Local.json`: list and create).
    {member?, collection?} =
      if member? and length(methods) > 1, do: {false, true}, else: {member?, collection?}

    segments = segments(path)

    if Enum.all?(segments, &param?/1) do
      nil
    else
      {resources, tail} = split_tail(segments, method, collection?, member?)

      {module, function} =
        case {method, tail} do
          {"get", :collection} -> {resources, "list"}
          {"post", :collection} -> {resources, "create"}
          {"get", :item} -> {resources, "retrieve"}
          {"get", :singleton} -> {resources, "retrieve"}
          # POST /audio/speech makes something; POST /organization/spend_limit,
          # which can also be read, changes it.
          {"post", :singleton} -> {resources, if("get" in methods, do: "update", else: "create")}
          {m, :singleton} when m in ["put", "patch"] -> {resources, "update"}
          {"delete", :singleton} -> {resources, "delete"}
          {m, :item} when m in ["post", "put", "patch"] -> {resources, "update"}
          {"delete", :item} -> {resources, "delete"}
          {"delete", :collection} -> {resources, "delete_all"}
          {_, {:action, action}} -> {resources, function_name(action)}
          {m, :collection} -> {resources, m}
        end

      %{
        module: Enum.map(namespace(path) ++ module, &module_part/1),
        function: function,
        strategy: :path
      }
    end
  end

  @doc false
  # The path without its query: "/responses?beta=true" -> "/responses".
  def path_only(path), do: path |> String.split("?", parts: 2) |> hd()

  defp segments(path) do
    path
    |> path_only()
    |> String.split("/", trim: true)
    |> Enum.reject(&version_segment?/1)
    # Twilio: /Accounts/{AccountSid}/Calls.json
    |> Enum.map(&String.replace(&1, ~r/\.(json|xml|csv)\z/, ""))
  end

  # A flag in the path's own query is a namespace: OpenAI's
  # `/responses?beta=true` is the official SDK's `beta.responses`.
  defp namespace(path) do
    case String.split(path, "?", parts: 2) do
      [_, query] -> for {flag, "true"} <- URI.decode_query(query), do: flag
      _ -> []
    end
  end

  # Returns {resource_names, :collection | :item | :singleton | {:action, name}}.
  defp split_tail(segments, method, collection?, member?) do
    statics = Enum.reject(segments, &param?/1)
    last = List.last(segments)
    after_param? = length(segments) >= 2 and param?(Enum.at(segments, -2))

    cond do
      segments == [] ->
        {["Root"], :collection}

      param?(last) ->
        {statics, :item}

      plural?(last) or collection? ->
        {statics, :collection}

      # A singular name beside the collection's items is something you do
      # with the collection: `Customers.search`, `Stream.mediawiki_recentchange`.
      member? and length(statics) > 1 ->
        {Enum.drop(statics, -1), {:action, last}}

      # A singular segment after a parameter, called with POST, is an action
      # on the item (`/payment_intents/{id}/cancel`). Reads are never
      # actions: `GET /charges/{id}/dispute` reads the charge's dispute.
      after_param? and method == "post" ->
        {Enum.drop(statics, -1), {:action, last}}

      # So is a verb: `POST /fine_tuning/alpha/graders/validate`. A noun
      # (`POST /audio/speech`) is a thing being made, below.
      method == "post" and length(statics) > 1 and verb?(last) ->
        {Enum.drop(statics, -1), {:action, last}}

      # Any other singular resource is a single thing, not a collection
      # (`/organization/spend_limit`, `/charges/{id}/dispute`).
      true ->
        {statics, :singleton}
    end
  end

  defp param?(segment), do: String.starts_with?(segment, "{")

  # Verbs that name an action when they end a path.
  @verbs ~w(accept activate apply approve archive authorize cancel capture check close compute
    confirm count deactivate decline disable enable estimate expire export extend finalize
    generate import invalidate lock pause preview publish query refresh refund regenerate reject
    renew reopen reset restore resume retry revoke rotate run search send simulate start stop
    submit suspend sync test transfer unlock update upload validate verify void)
  defp verb?(segment), do: String.downcase(segment) in @verbs

  @irregular_plurals ~w(people children data media criteria indices statistics settings)
  defp plural?(word) do
    word = String.downcase(word)

    word in @irregular_plurals or
      (String.ends_with?(word, "s") and not String.ends_with?(word, "ss"))
  end

  # v1, v2beta, 2010-04-01, api
  defp version_segment?(segment) do
    Regex.match?(~r/\Av\d+[a-z0-9]*\z/i, segment) or
      Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, segment) or
      segment in ["api"]
  end

  ## Words and cases

  @doc ~S'A module name part: `"vector stores"`, `"vector_stores"`, `"vector-stores"` -> `"VectorStores"`.'
  @spec module_part(String.t()) :: String.t()
  def module_part(name) do
    name
    |> words()
    |> Enum.map_join(&String.capitalize/1)
    |> ensure_leading_letter("M")
  end

  @doc ~S'A function or field name: `"createChatCompletion"`, `"repos/get-pages"` -> snake_case.'
  @spec function_name(String.t()) :: String.t()
  def function_name(name) do
    name
    |> words()
    |> Enum.join("_")
    |> ensure_leading_letter("op_")
  end

  @doc """
  The package name for a base module, as the vendor writes it: `OpenAI` is
  `openai`, `GitHub` is `github` (not `open_ai`, `git_hub`). Used for the
  app, the directory and the API key's environment variable.
  """
  @spec package(String.t()) :: String.t()
  def package(base) do
    base |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
  end

  @doc "Splits camelCase, PascalCase, kebab, snake, dotted and spaced names into lowercase words."
  @spec words(String.t()) :: [String.t()]
  def words(name) do
    name
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1 \\2")
    |> String.split(~r/[^A-Za-z0-9]+/, trim: true)
    |> Enum.map(&String.downcase/1)
  end

  defp ensure_leading_letter("", fallback), do: fallback

  defp ensure_leading_letter(name, fallback) do
    if Regex.match?(~r/\A[A-Za-z]/, name), do: name, else: fallback <> name
  end

  # "Api20100401RecordingTranscription" -> "RecordingTranscription"
  defp strip_version_prefix(tag), do: Regex.replace(~r/\AApi(V?\d+)+(?=[A-Z])/, tag, "")

  @doc false
  # create_chat_completion in Chat -> create_completion; list_recording in Recording -> list
  def drop_module_words(function, module) do
    module_words = words(module)
    fn_words = String.split(function, "_")
    n = length(module_words)

    stripped =
      fn_words
      |> Enum.chunk_every(n, 1, :discard)
      |> Enum.find_index(&(singular(&1) == singular(module_words)))
      |> case do
        nil -> fn_words
        i -> Enum.take(fn_words, i) ++ Enum.drop(fn_words, i + n)
      end

    if stripped == [], do: function, else: Enum.join(stripped, "_")
  end

  defp singular(words), do: Enum.map(words, &String.trim_trailing(&1, "s"))
end
