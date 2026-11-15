defmodule Infusion.Config do
  @moduledoc """
  `infusion.exs`: what the spec doesn't say.

  Real specs leave out how to authenticate (GitHub), how lists page, and the
  names the official SDKs use. An `infusion.exs` file says it, so an SDK can
  be regenerated from the vendor's spec without editing generated code:

      # infusion.exs
      [
        name: "GitHub",
        spec: "https://raw.githubusercontent.com/github/rest-api-description/main/descriptions/api.github.com/api.github.com.json",
        app: :github_sdk,

        # The client
        base_url: "https://api.github.com",
        auth: :bearer,
        env_var: "GITHUB_TOKEN",
        headers: [{"x-github-api-version", "2022-11-28"}],

        # Names
        rename_modules: %{"Apps" => "GitHubApps"},
        rename: %{
          "repos/list-for-authenticated-user" => "Repos.list_mine",
          "GET /user" => "Users.me"
        },

        # Pagination, when the generator guesses wrong
        pagination: %{
          "Repos.list_for_org" => [style: :page, per_page: "per_page"],
          "Search.code" => false
        }
      ]

  Then `mix infusion.gen --config infusion.exs`. Every key is optional
  except `name` and `spec` (which can also come from the command line).

  ## Generator settings

    * `name`: the base module, `"GitHub"` or `GitHub`
    * `spec`: the spec's URL or path (relative to this file)
    * `out`: where to write the SDK (relative to this file; default
      `<name>_sdk` in the current directory)
    * `app`, `version`, `license`, `env_var`: see `mix infusion.gen`. For
      basic auth from two variables, `env_var` can be a pair:
      `{"TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN"}`
    * `description`, `links`: the package's description and links in the
      generated `mix.exs`: `links: %{"GitHub" => "https://github.com/..."}`
    * `keep`: files that are yours once they exist, written only when
      missing: `keep: ["README.md"]` for a hand-written README
    * `schema_names`: `:full` (default) or `:last_segment`, which names a
      dotted schema by its last part when no other schema has it:
      Twilio's `api.v2010.account.message` becomes `Schemas.Message`, not
      `Schemas.ApiV2010AccountMessage`

  ## Client settings

  Defaults the generated client starts with; users can still override them
  in their config or per call. See `Infusion.Runtime.Config`.

    * `base_url`: replaces the spec's first server (Wikimedia's spec has none)
    * `auth`: `:bearer`, `:basic`, `{:header, "x-api-key"}`,
      `{:query, "key"}`, or `nil`. Replaces what the spec's security schemes
      say; the credential is read from `env_var`.
    * `headers`: sent with every request, `[{"name", "value"}]`
    * `timeout`, `max_retries`, `idempotency_header`, `retry_count_header`,
      `request_id_headers`, `form_style`

  ## Names

  Operations are picked by any of:

    * `"GET /repos/{owner}/{repo}"`: method and path, as in the spec
    * `"repos/get"`: the operation ID
    * `"Repos.get"`: the name Infusion would give it, without the base module

  `rename` maps an operation to `"Module.function"` (or just `"function"`, to
  keep the module). `rename_modules` renames a module and everything under
  it: `%{"WebhookEndpoints" => "Webhooks"}` also turns
  `WebhookEndpoints.Events` into `Webhooks.Events`. Module renames apply
  first. A name in either map that matches nothing is a warning, and two
  operations ending up with the same name is an error.

  ## Path parameters from the client

  `path_defaults` fills a path parameter from a client setting, so calls
  don't take it. Twilio puts the account in every path
  (`/2010-04-01/Accounts/{AccountSid}/Messages.json`), and its official
  SDKs take it from the client:

      path_defaults: %{"AccountSid" => {:account_sid, {:env, "TWILIO_ACCOUNT_SID"}}}

  makes `Twilio.Messages.create(params)` read `account_sid` from
  `config :twilio_sdk, account_sid: ...` (default: the environment
  variable), and a call can still pass `account_sid: "AC..."`. A bare atom
  (`"AccountSid" => :account_sid`) means no default.

  ## Pagination

  `pagination` maps an operation to `false` (no `_all` function) or to how
  it pages:

    * `style: :cursor_after`, `param:` (default `"after"`)
    * `style: :cursor`, `param:`, `from:` (the response field holding the
      next cursor, `"next_cursor"` or `"meta.next_cursor"`)
    * `style: :next_url`, `from:`
    * `style: :page`, `param:` (default `"page"`), optional `per_page:` and
      `total_pages:`
    * `style: :offset`, `param:` (default `"offset"`), `limit:` (default
      `"limit"`)
    * `style: :link_header`

  plus `items:`, where the list is in the response (`"data"`, `"meta.items"`,
  or `""` for the response itself), when Infusion can't find it.
  """

  alias Infusion.IR
  alias Infusion.IR.Operation

  @generator_keys [
    :name,
    :spec,
    :out,
    :app,
    :version,
    :license,
    :description,
    :links,
    :keep,
    :env_var,
    :schema_names
  ]
  @client_keys [
    :base_url,
    :auth,
    :headers,
    :timeout,
    :max_retries,
    :idempotency_header,
    :retry_count_header,
    :request_id_headers,
    :form_style
  ]
  @naming_keys [:rename, :rename_modules, :path_defaults, :pagination]
  @keys @generator_keys ++ @client_keys ++ @naming_keys

  @styles [:cursor_after, :cursor, :next_url, :page, :offset, :link_header]
  @style_keys [:style, :param, :from, :items, :per_page, :total_pages, :limit]
  @methods ~w(GET PUT POST DELETE PATCH HEAD OPTIONS)

  @doc "Every key `infusion.exs` can have."
  def keys, do: @keys

  @doc """
  The client settings among `opts`: they become the generated client's
  defaults. `auth` is left out (it goes through the IR, with the API key).
  """
  @spec client_defaults(keyword) :: keyword
  def client_defaults(opts) do
    # The defaults of settings that fill path parameters: account_sid: {:env, ...}
    path_settings =
      for {_name, {setting, default}} <- Enum.sort(opts[:path_defaults] || %{}),
          do: {setting, default}

    Keyword.take(opts, @client_keys -- [:base_url, :auth]) ++ path_settings
  end

  @doc """
  Reads and checks an `infusion.exs` file. Relative `spec` and `out` paths
  are made relative to the file.
  """
  @spec load(Path.t()) :: {:ok, keyword} | {:error, String.t()}
  def load(path) do
    with {:ok, value} <- eval(path),
         :ok <- validate(value) do
      dir = path |> Path.expand() |> Path.dirname()
      {:ok, value |> expand(:spec, dir) |> expand(:out, dir)}
    end
  end

  defp eval(path) do
    if File.regular?(path) do
      {value, _binding} = Code.eval_file(path)
      {:ok, value}
    else
      {:error, "#{path}: no such file"}
    end
  rescue
    e -> {:error, "#{path}: #{Exception.message(e)}"}
  end

  defp expand(opts, key, dir) do
    case opts[key] do
      nil -> opts
      value -> if url?(value), do: opts, else: Keyword.put(opts, key, Path.expand(value, dir))
    end
  end

  defp url?(value), do: String.starts_with?(value, ["http://", "https://"])

  @doc "Checks a config (the keyword list `infusion.exs` evaluates to)."
  @spec validate(term) :: :ok | {:error, String.t()}
  def validate(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Enum.find_value(opts, :ok, fn {key, value} ->
        case check(key, value) do
          :ok -> nil
          {:error, message} -> {:error, "infusion.exs: #{message}"}
        end
      end)
    else
      {:error, "infusion.exs must be a keyword list, like [name: \"GitHub\", spec: \"...\"]"}
    end
  end

  def validate(_other),
    do: {:error, "infusion.exs must be a keyword list, like [name: \"GitHub\", spec: \"...\"]"}

  defp check(:name, value) when is_atom(value) and value != nil, do: check(:name, inspect(value))

  defp check(:name, value) when is_binary(value) do
    if module_name?(value),
      do: :ok,
      else: {:error, ":name must be a module name like \"GitHub\", got #{inspect(value)}"}
  end

  defp check(key, value)
       when key in [:spec, :out, :version, :license, :description, :env_var, :base_url] and
              is_binary(value),
       do: :ok

  defp check(:links, value) when is_map(value) do
    if Enum.all?(value, fn {k, v} -> is_binary(k) and is_binary(v) end),
      do: :ok,
      else: expected(:links, ~s(a map of names to URLs, like %{"GitHub" => "https://..."}), value)
  end

  defp check(:keep, value) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: :ok,
      else: expected(:keep, ~s(a list of paths, like ["README.md"]), value)
  end

  defp check(:env_var, {user, password}) when is_binary(user) and is_binary(password), do: :ok

  defp check(:env_var, value),
    do: expected(:env_var, ~s(a variable name, or a pair {"USER_VAR", "PASSWORD_VAR"}), value)

  defp check(:schema_names, value) when value in [:full, :last_segment], do: :ok
  defp check(:schema_names, value), do: expected(:schema_names, ":full or :last_segment", value)

  defp check(:path_defaults, value) when is_map(value) do
    Enum.find_value(value, :ok, fn
      {name, setting}
      when is_binary(name) and is_atom(setting) and setting not in [nil, true, false] ->
        nil

      {name, {setting, _default}}
      when is_binary(name) and is_atom(setting) and setting not in [nil, true, false] ->
        nil

      {name, setting} ->
        {:error,
         "path_defaults: #{inspect(name)} => #{inspect(setting)}: give the path parameter's name and a setting, like \"AccountSid\" => :account_sid or {:account_sid, {:env, \"TWILIO_ACCOUNT_SID\"}}"}
    end)
  end

  defp check(key, value) when key in [:idempotency_header, :retry_count_header] do
    if is_binary(value) or value == nil, do: :ok, else: expected(key, "a header name", value)
  end

  defp check(:app, value) when is_atom(value) and value not in [nil, true, false], do: :ok

  defp check(:auth, value)
       when value in [:bearer, :basic, nil],
       do: :ok

  defp check(:auth, {where, name}) when where in [:header, :query] and is_binary(name), do: :ok

  defp check(:auth, value),
    do:
      expected(
        :auth,
        ~s(:bearer, :basic, {:header, "x-api-key"}, {:query, "key"} or nil),
        value
      )

  defp check(:headers, value) when is_map(value), do: check(:headers, Map.to_list(value))

  defp check(:headers, value) when is_list(value) do
    if Enum.all?(value, &match?({k, v} when is_binary(k) and is_binary(v), &1)),
      do: :ok,
      else: expected(:headers, ~s([{"name", "value"}]), value)
  end

  defp check(key, value)
       when key in [:timeout, :max_retries] and is_integer(value) and value >= 0,
       do: :ok

  defp check(:request_id_headers, value) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: :ok,
      else: expected(:request_id_headers, "a list of header names", value)
  end

  defp check(:form_style, value) when is_atom(value), do: :ok

  defp check(:rename_modules, value) when is_map(value) do
    Enum.find_value(value, :ok, fn
      {from, to} when is_binary(from) and is_binary(to) ->
        if module_path?(from) and module_path?(to),
          do: nil,
          else:
            {:error,
             "rename_modules: #{inspect(from)} => #{inspect(to)}: both must be module names like \"Repos\" or \"Beta.Threads\""}

      {from, to} ->
        {:error, "rename_modules: #{inspect(from)} => #{inspect(to)}: both must be strings"}
    end)
  end

  defp check(:rename, value) when is_map(value) do
    Enum.find_value(value, :ok, fn
      {from, to} when is_binary(from) and is_binary(to) ->
        case parse_name(to) do
          {:ok, _} -> nil
          :error -> {:error, "rename: #{inspect(from)} => #{inspect(to)}: #{name_hint()}"}
        end

      {from, to} ->
        {:error, "rename: #{inspect(from)} => #{inspect(to)}: both must be strings"}
    end)
  end

  defp check(:pagination, value) when is_map(value) do
    Enum.find_value(value, :ok, fn
      {key, _} when not is_binary(key) ->
        {:error, "pagination: keys pick operations and must be strings, got #{inspect(key)}"}

      {_key, false} ->
        nil

      {key, setting} ->
        case pagination(setting) do
          {:ok, _} -> nil
          {:error, message} -> {:error, "pagination: #{inspect(key)}: #{message}"}
        end
    end)
  end

  defp check(key, _value) when key not in @keys do
    {:error,
     "unknown key #{inspect(key)}; the keys are #{Enum.map_join(@keys, ", ", &inspect/1)}"}
  end

  defp check(key, value) do
    expected(
      key,
      case key do
        k when k in [:rename, :rename_modules, :pagination, :path_defaults, :links] -> "a map"
        :keep -> "a list of paths"
        k when k in [:timeout, :max_retries] -> "a non-negative integer"
        :app -> "an atom, like :github_sdk"
        :form_style -> "an atom"
        :request_id_headers -> "a list of header names"
        _ -> "a string"
      end,
      value
    )
  end

  defp expected(key, what, value),
    do: {:error, "#{inspect(key)} must be #{what}, got #{inspect(value)}"}

  defp module_name?(name), do: Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/, name)
  defp module_path?(name), do: module_name?(name)

  defp name_hint,
    do: ~s(give "Module.function" or "function", like "Repos.list_mine")

  # "Repos.list_mine" -> {:ok, {["Repos"], "list_mine"}}; "list_mine" -> {:ok, {nil, "list_mine"}}
  defp parse_name(name) do
    parts = String.split(name, ".")
    {modules, [function]} = Enum.split(parts, -1)

    cond do
      not Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*$/, function) -> :error
      modules == [] -> {:ok, {nil, function}}
      module_path?(Enum.join(modules, ".")) -> {:ok, {modules, function}}
      true -> :error
    end
  end

  # A pagination setting, normalized to the map the runtime reads.
  defp pagination(setting) when is_map(setting), do: pagination(Map.to_list(setting))

  defp pagination(setting) when is_list(setting) do
    cond do
      not Keyword.keyword?(setting) ->
        {:error, "give a keyword list like [style: :page]"}

      (unknown = Keyword.keys(setting) -- @style_keys) != [] ->
        {:error,
         "unknown #{Enum.map_join(unknown, ", ", &inspect/1)}; the keys are #{Enum.map_join(@style_keys, ", ", &inspect/1)}"}

      setting[:style] not in @styles ->
        {:error,
         ":style must be one of #{Enum.map_join(@styles, ", ", &inspect/1)}, got #{inspect(setting[:style])}"}

      not Enum.all?(Keyword.delete(setting, :style), fn {_k, v} -> is_binary(v) end) ->
        {:error, "every setting but :style must be a string"}

      true ->
        style = setting[:style]

        defaults =
          case style do
            :cursor_after -> [param: "after"]
            :page -> [param: "page"]
            :offset -> [param: "offset", limit: "limit"]
            _ -> []
          end

        map = Map.new(Keyword.merge(defaults, setting))
        required = %{cursor: [:param, :from], next_url: [:from]}[style] || []

        case Enum.reject(required, &Map.has_key?(map, &1)) do
          [] ->
            {:ok, map |> path(:from) |> path(:total_pages) |> path(:items)}

          missing ->
            {:error,
             "style #{inspect(style)} needs #{Enum.map_join(missing, " and ", &inspect/1)}"}
        end
    end
  end

  defp pagination(other), do: {:error, "give false or a keyword list, got #{inspect(other)}"}

  # "meta.next_cursor" -> ["meta", "next_cursor"]; "" -> [].
  defp path(map, key) do
    case map do
      %{^key => ""} -> Map.put(map, key, [])
      %{^key => value} when is_binary(value) -> Map.put(map, key, String.split(value, "."))
      _ -> map
    end
  end

  @doc """
  Applies the config to the IR: client settings that live in the IR
  (`base_url`, `auth`), renames, and pagination overrides. Returns the new
  IR and warnings (names that match no operation).
  """
  @spec apply(%IR{}, keyword) :: {:ok, %IR{}, [String.t()]} | {:error, String.t()}
  def apply(%IR{} = ir, opts) do
    with :ok <- validate(opts) do
      ir =
        ir
        |> put_base_url(opts[:base_url])
        |> put_auth(opts)

      # Operations are picked by their names before any rename.
      originals = Enum.map(ir.operations, &{&1, keys(&1)})

      {renamed, module_warnings} = rename_modules(originals, opts[:rename_modules] || %{})
      {renamed, rename_warnings} = rename(renamed, opts[:rename] || %{})

      {renamed, path_warnings} = path_defaults(renamed, opts[:path_defaults] || %{})

      with :ok <- check_collisions(renamed),
           {:ok, paged, pagination_warnings} <- paginate(renamed, opts[:pagination] || %{}, ir) do
        {:ok, %{ir | operations: Enum.map(paged, &elem(&1, 0))},
         module_warnings ++ rename_warnings ++ path_warnings ++ pagination_warnings}
      end
    end
  end

  defp put_base_url(ir, nil), do: ir
  defp put_base_url(ir, url), do: %{ir | servers: [%{url: url, variables: %{}} | ir.servers]}

  defp put_auth(ir, opts) do
    if Keyword.has_key?(opts, :auth), do: %{ir | auth: opts[:auth]}, else: ir
  end

  # The strings that pick an operation: "GET /path", its ID, "Module.function".
  defp keys(%Operation{} = op) do
    [
      "#{op.method |> Atom.to_string() |> String.upcase()} #{op.path}",
      op.id,
      name(op)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp name(%Operation{module: module, function: function}),
    do: Enum.join(module ++ [function], ".")

  defp rename_modules(ops, renames) when renames == %{}, do: {ops, []}

  defp rename_modules(ops, renames) do
    # The longest matching prefix wins: "Beta.Threads" before "Beta".
    prefixes =
      renames
      |> Enum.map(fn {from, to} -> {String.split(from, "."), String.split(to, "."), from} end)
      |> Enum.sort_by(fn {from, _, _} -> -length(from) end)

    {ops, used} =
      Enum.map_reduce(ops, MapSet.new(), fn {op, keys}, used ->
        case Enum.find(prefixes, fn {from, _, _} -> List.starts_with?(op.module, from) end) do
          nil ->
            {{op, keys}, used}

          {from, to, key} ->
            module = to ++ Enum.drop(op.module, length(from))
            {{%{op | module: module}, keys}, MapSet.put(used, key)}
        end
      end)

    {ops, unused("rename_modules", Map.keys(renames), used, "no module")}
  end

  defp rename(ops, renames) when renames == %{}, do: {ops, []}

  defp rename(ops, renames) do
    {ops, used} =
      Enum.map_reduce(ops, MapSet.new(), fn {op, keys}, used ->
        case Enum.find(keys, &Map.has_key?(renames, &1)) do
          nil ->
            {{op, keys}, used}

          key ->
            {:ok, {module, function}} = parse_name(renames[key])
            op = %{op | module: module || op.module, function: function}
            {{op, keys}, MapSet.put(used, key)}
        end
      end)

    {ops, unused("rename", Map.keys(renames), used, "no operation")}
  end

  # Path parameters the client fills leave the function's arguments.
  defp path_defaults(ops, defaults) when defaults == %{}, do: {ops, []}

  defp path_defaults(ops, defaults) do
    {ops, used} =
      Enum.map_reduce(ops, MapSet.new(), fn {op, keys}, used ->
        {filled, kept} = Enum.split_with(op.path_params, &Map.has_key?(defaults, &1.name))

        client =
          Enum.map(filled, fn p ->
            case defaults[p.name] do
              {setting, _default} -> {p.name, setting}
              setting -> {p.name, setting}
            end
          end)

        op = %{op | path_params: kept, client_path_params: client}
        {{op, keys}, Enum.into(Enum.map(filled, & &1.name), used)}
      end)

    {ops, unused("path_defaults", Map.keys(defaults), used, "no path parameter")}
  end

  defp unused(setting, names, used, what) do
    for name <- Enum.sort(names), not MapSet.member?(used, name) do
      "infusion.exs #{setting}: #{inspect(name)} matches #{what}#{hint(name)}"
    end
  end

  defp hint(name) do
    case String.split(name, " ", parts: 2) do
      [method, "/" <> _] when method not in @methods ->
        " (methods are written in capitals, like \"GET /path\")"

      _ ->
        ""
    end
  end

  defp check_collisions(ops) do
    ops
    |> Enum.group_by(fn {op, _} -> {op.module, op.function} end)
    |> Enum.find_value(:ok, fn
      {_name, [_]} ->
        nil

      {_name, [{first, _} | _] = same} ->
        where =
          Enum.map_join(same, " and ", fn {op, _} ->
            "#{op.method |> Atom.to_string() |> String.upcase()} #{op.path}"
          end)

        {:error, "infusion.exs: #{name(first)} would be #{where}; rename one of them"}
    end)
  end

  defp paginate(ops, settings, _ir) when settings == %{}, do: {:ok, ops, []}

  defp paginate(ops, settings, ir) do
    result =
      Enum.reduce_while(ops, {[], MapSet.new()}, fn {op, keys}, {acc, used} ->
        # Picked by the new name too, so a setting can follow a rename.
        case Enum.find(keys ++ [name(op)], &Map.has_key?(settings, &1)) do
          nil ->
            {:cont, {[{op, keys} | acc], used}}

          key ->
            case pagination_for(op, settings[key], ir) do
              {:ok, setting} ->
                {:cont, {[{%{op | pagination: setting}, keys} | acc], MapSet.put(used, key)}}

              {:error, message} ->
                {:halt, {:error, "infusion.exs pagination: #{inspect(key)}: #{message}"}}
            end
        end
      end)

    case result do
      {:error, _} = error ->
        error

      {ops, used} ->
        {:ok, Enum.reverse(ops), unused("pagination", Map.keys(settings), used, "no operation")}
    end
  end

  defp pagination_for(_op, false, _ir), do: {:ok, false}

  defp pagination_for(op, setting, ir) do
    {:ok, setting} = pagination(setting)

    if Map.has_key?(setting, :items) or Infusion.Gen.Pagination.items(op, ir) != nil,
      do: {:ok, setting},
      else:
        {:error,
         ~s(can't find the list in the response; say where it is with items: "data" (or "" for the response itself\))}
  end
end
