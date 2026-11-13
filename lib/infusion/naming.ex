defmodule Infusion.Naming do
  @moduledoc """
  Turns OpenAPI names into Elixir module and function names.

  Each operation gets a module path (`["Repos"]`, `["ZeroTrust", "Devices"]`)
  and a function name, from the first strategy that applies:

    1. **Vendor SDK hints**: `x-fern-sdk-group-name` (dot-separated groups)
       and `x-fern-sdk-method-name`. Cloudflare sets them on nearly every
       operation, so its SDK matches the official ones.
    2. **`group/action` operation IDs**, as GitHub uses (`repos/get`).
    3. **The path**, when the operation has no tag (all of Stripe, part of
       OpenAI): `GET /v1/customers` is `Customers.list`, `POST
       /v1/customers/{id}` is `Customers.update`, `POST
       /v1/payment_intents/{id}/cancel` is `PaymentIntents.cancel`, and
       `/v1/customers/{id}/sources` is a nested `Customers.Sources`.
    4. **The tag and the operation ID**, with version prefixes taken off the
       tag (Twilio's `Api20100401Recording`) and the module's words taken off
       the function (`list_recording` in `Recording` is `list`).
  """

  @type operation_name :: %{module: [String.t()], function: String.t(), strategy: atom}

  @doc "Names an operation. `op` is the operation object, `path` and `method` its location."
  @spec operation(map, String.t(), String.t()) :: operation_name
  def operation(op, path, method) do
    cond do
      is_binary(op["x-fern-sdk-group-name"]) and is_binary(op["x-fern-sdk-method-name"]) ->
        %{
          module: op["x-fern-sdk-group-name"] |> String.split(".") |> Enum.map(&module_part/1),
          function: function_name(op["x-fern-sdk-method-name"]),
          strategy: :vendor_hint
        }

      is_binary(op["operationId"]) and String.contains?(op["operationId"], "/") ->
        [group | rest] = String.split(op["operationId"], "/")

        %{
          module: [module_part(group)],
          function: function_name(Enum.join(rest, "_")),
          strategy: :grouped_id
        }

      tag(op) == nil ->
        rest_name(path, method)

      true ->
        module = tag(op) |> strip_version_prefix() |> module_part()

        function =
          op["operationId"]
          |> Kernel.||("#{method}_#{path}")
          |> function_name()
          |> drop_module_words(module)

        %{module: [module], function: function, strategy: :tag}
    end
  end

  defp tag(%{"tags" => [tag | _]}) when is_binary(tag) and tag != "", do: tag
  defp tag(_), do: nil

  ## Path-based (REST) naming

  @doc false
  def rest_name(path, method) do
    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.reject(&version_segment?/1)

    {resources, tail} = split_tail(segments, method)

    {module, function} =
      case {method, tail} do
        {"get", :collection} -> {resources, "list"}
        {"post", :collection} -> {resources, "create"}
        {"get", :item} -> {resources, "retrieve"}
        {"get", :singleton} -> {resources, "retrieve"}
        {m, :singleton} when m in ["post", "put", "patch"] -> {resources, "update"}
        {"delete", :singleton} -> {resources, "delete"}
        {m, :item} when m in ["post", "put", "patch"] -> {resources, "update"}
        {"delete", :item} -> {resources, "delete"}
        {"delete", :collection} -> {resources, "delete_all"}
        {_, {:action, action}} -> {resources, function_name(action)}
        {m, :collection} -> {resources, m}
      end

    %{module: Enum.map(module, &module_part/1), function: function, strategy: :path}
  end

  # Returns {resource_names, :collection | :item | :singleton | {:action, name}}.
  defp split_tail(segments, method) do
    statics = Enum.reject(segments, &param?/1)
    last = List.last(segments)
    after_param? = length(segments) >= 2 and param?(Enum.at(segments, -2))

    cond do
      segments == [] ->
        {["Root"], :collection}

      param?(last) ->
        {statics, :item}

      plural?(last) ->
        {statics, :collection}

      # A singular segment after a parameter, called with POST, is an action
      # on the item (`/payment_intents/{id}/cancel`). Reads are never
      # actions: `GET /charges/{id}/dispute` reads the charge's dispute.
      after_param? and method == "post" ->
        {Enum.drop(statics, -1), {:action, last}}

      # Any other singular resource is a single thing, not a collection
      # (`/organization/spend_limit`, `/charges/{id}/dispute`).
      true ->
        {statics, :singleton}
    end
  end

  defp param?(segment), do: String.starts_with?(segment, "{")

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

  # create_chat_completion in Chat -> create_completion; list_recording in Recording -> list
  defp drop_module_words(function, module) do
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
