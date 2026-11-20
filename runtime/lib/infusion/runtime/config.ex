defmodule Infusion.Runtime.Config do
  @moduledoc """
  Client settings, merged from layers: the SDK's generated defaults, then the
  application environment, then the options of a single call.

      # config/runtime.exs
      config :openai_sdk, api_key: System.fetch_env!("OPENAI_API_KEY"), max_retries: 5

      # one call
      OpenAI.Models.list(timeout: 5_000, max_retries: 0)

  Settings:

    * `:base_url`: where requests go
    * `:api_key`: the credential, as a string, `{user, password}` for basic
      auth, `{:env, "VAR"}` (read on each request) or a 0-arity function
    * `:auth`: how the credential is sent: `:bearer`, `:basic`,
      `{:header, "x-api-key"}`, `{:query, "key"}`, or `nil`
    * `:headers`: extra headers, `[{"name", "value"}]`; a later layer
      replaces a header of the same name
    * `:timeout`: milliseconds to wait for a response (default 10 minutes)
    * `:max_retries`: retries after the first attempt (default 2)
    * `:idempotency_header`: when set, every non-GET request gets this header
      with a key that stays the same across its retries
    * `:retry_count_header`: when set, each request says which retry it is
    * `:request_id_headers`: response headers holding the API's request ID
    * `:form_style`: how form bodies encode lists, see `Infusion.Runtime.Form`
    * `:user_agent`: the `user-agent` header
    * `:req_options`: passed to `Req.new/1` as is, e.g. `plug: {Req.Test, MyStub}`
    * `:sleep`: how to wait between retries, `fn ms -> ... end` (for tests)
    * `:drift`: compare responses with the spec, `true`, `false` or the
      share of calls to check; see `Infusion.Runtime.Drift`

  Any other key is kept in `extra`, for settings an SDK defines itself, such
  as Twilio's `:account_sid` (see `setting/2`).
  """

  @defaults [
    base_url: nil,
    api_key: nil,
    auth: :bearer,
    headers: [],
    timeout: 600_000,
    max_retries: 2,
    idempotency_header: nil,
    retry_count_header: nil,
    request_id_headers: [
      "x-request-id",
      "request-id",
      "x-github-request-id",
      "twilio-request-id",
      "cf-ray"
    ],
    form_style: :indexed,
    user_agent: nil,
    req_options: [],
    sleep: nil,
    drift: nil
  ]

  defstruct @defaults ++ [extra: %{}]

  @type t :: %__MODULE__{}

  @keys Keyword.keys(@defaults)

  @doc """
  Merges `layers` (keyword lists or maps) from left to right. Keys that are
  not settings are ignored, so a call's options can be passed as a layer.
  """
  @spec new([keyword | map]) :: t
  def new(layers) do
    Enum.reduce(layers, %__MODULE__{}, &merge(&2, &1))
  end

  @doc "Merges one layer into `config`."
  @spec merge(t, keyword | map | nil) :: t
  def merge(config, nil), do: config

  def merge(config, layer) do
    Enum.reduce(layer, config, fn
      {:headers, headers}, acc ->
        %{acc | headers: merge_headers(acc.headers, headers)}

      {:req_options, options}, acc ->
        %{acc | req_options: Keyword.merge(acc.req_options, options)}

      {key, value}, acc when key in @keys ->
        Map.put(acc, key, value)

      {key, value}, acc when is_atom(key) ->
        %{acc | extra: Map.put(acc.extra, key, value)}

      _other, acc ->
        acc
    end)
  end

  defp merge_headers(old, new) do
    new = Enum.map(new, fn {k, v} -> {String.downcase(to_string(k)), v} end)
    names = MapSet.new(new, &elem(&1, 0))

    Enum.reject(old, fn {k, _} -> MapSet.member?(names, String.downcase(to_string(k))) end) ++
      new
  end

  @doc false
  def credential(%__MODULE__{api_key: key}), do: resolve(key)

  @doc """
  The value of a setting the SDK defines itself (`:account_sid`), resolved
  like the API key: `{:env, "VAR"}` and functions are read now.
  """
  @spec setting(t, atom) :: term
  def setting(%__MODULE__{extra: extra}, key), do: resolve(Map.get(extra, key))

  defp resolve({:env, var}), do: System.get_env(var)
  defp resolve(fun) when is_function(fun, 0), do: resolve(fun.())

  # Basic auth from two places: {{:env, "ACCOUNT_SID"}, {:env, "AUTH_TOKEN"}}.
  # Missing either part is no credential at all.
  defp resolve({user, password}) do
    case {resolve(user), resolve(password)} do
      {nil, _} -> nil
      {_, nil} -> nil
      pair -> pair
    end
  end

  defp resolve(value), do: value
end
