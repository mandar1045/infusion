defmodule Infusion.Runtime.Drift do
  @moduledoc """
  Notices where an API's real responses disagree with its OpenAPI spec.

  Specs are written by people and drift from the servers they describe: a
  field that is documented as always present goes missing, one documented
  as a string arrives as `null`, new fields and enum values ship before the
  spec mentions them. Generated SDKs inherit every one of those mistakes.

  Turn drift checking on, and every successful response and stream event
  is compared with the types the SDK was generated from:

      # config/config.exs: every Infusion SDK in the app
      config :infusion_runtime, drift: true

      # or one SDK, or one call
      config :github, drift: true
      GitHub.Repos.get("elixir-lang", "elixir", drift: true)

      # or a sample of calls, for production
      config :infusion_runtime, drift: 0.01

  Then look at what it saw:

      Infusion.Runtime.Drift.report()
      Infusion.Runtime.Drift.export("drift.json")

  `mix infusion.drift drift.json`, run in the SDK's project, turns the
  export into spec patches that fix the SDK on its next regeneration, and
  into an issue for the API's owners.

  ## What is checked

    * `:undocumented_field`: a field the schema doesn't list (keys allowed
      by a typed `additionalProperties` are checked against its type instead)
    * `:missing_required`: a required field that isn't there
    * `:unexpected_null`: `null` in a field the spec says can't be null
    * `:wrong_type`: a value of another JSON type than the spec's
    * `:unknown_enum`: a value outside the enum
    * `:unknown_variant`: a discriminator value the union doesn't map
    * `:unmatched_union`: a value no variant of a union fits

  Findings are kept per kind, schema, field and operation, with a count.
  **No response data is kept**, only JSON types and enum or discriminator
  values, so a report can be shared without leaking what the API returned.
  Checking walks each response once more, which is why it is off by
  default and can be sampled. At most `#{10_000}` different findings are
  kept.

  ## Telemetry

  `[:infusion, :drift]` with `%{count: n}` and `%{operation: "GET /path",
  findings: [finding]}`, once per response or event with findings, whether
  or not they are new.
  """

  @table __MODULE__
  @max_findings 10_000
  @kinds ~w(undocumented_field missing_required unexpected_null wrong_type unknown_enum unknown_variant unmatched_union)a

  @typedoc """
  One disagreement. `schema` is the generated module whose field it is
  (`nil` at the top of a response that isn't an object); `path` is where in
  that schema, like `"license"` or `"labels[].color"`.
  """
  @type finding :: %{
          kind: atom,
          schema: String.t() | nil,
          path: String.t(),
          expected: String.t() | nil,
          got: String.t() | nil
        }

  use GenServer

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    {:ok, nil}
  end

  ## Checking

  @doc """
  Compares parsed JSON with a `Infusion.Runtime.Schema` type and returns the
  findings. Pure: nothing is recorded.
  """
  @spec check(term, term) :: [finding]
  def check(json, type), do: json |> walk(type, nil, "", []) |> Enum.reverse()

  defp walk(nil, _type, _owner, _path, acc), do: acc
  defp walk(_json, nil, _owner, _path, acc), do: acc
  defp walk(_json, :any, _owner, _path, acc), do: acc

  defp walk(json, {:ref, module}, owner, path, acc) do
    cond do
      not Infusion.Runtime.Schema.struct_module?(module) ->
        walk(json, module.__schema__(:type), owner, path, acc)

      is_map(json) ->
        object(json, module, acc)

      true ->
        [finding(:wrong_type, owner, path, "object", json_type(json)) | acc]
    end
  end

  defp walk(json, {:array, type}, owner, path, acc) when is_list(json),
    do: Enum.reduce(json, acc, &walk(&1, type, owner, path <> "[]", &2))

  defp walk(json, {:map, type}, owner, path, acc) when is_map(json),
    do: Enum.reduce(json, acc, fn {_k, v}, acc -> walk(v, type, owner, path <> "{}", acc) end)

  defp walk(json, {:enum, values}, owner, path, acc) do
    cond do
      json in values -> acc
      scalar?(json) -> [finding(:unknown_enum, owner, path, nil, to_string(json)) | acc]
      true -> [finding(:wrong_type, owner, path, enum_type(values), json_type(json)) | acc]
    end
  end

  defp walk(_json, {:const, _}, _owner, _path, acc), do: acc

  defp walk(json, {:union, variants, discriminator}, owner, path, acc) do
    acc = unknown_tag(json, discriminator, owner, path, acc)

    case Infusion.Runtime.Schema.variant(json, variants, discriminator) do
      nil -> [finding(:unmatched_union, owner, path, nil, json_type(json)) | acc]
      type -> walk(json, type, owner, path, acc)
    end
  end

  defp walk(json, type, owner, path, acc) when is_atom(type) or is_tuple(type) do
    expected = expected_type(type)
    got = json_type(json)

    if expected == nil or got == expected or (expected == "number" and got == "integer"),
      do: acc,
      else: [finding(:wrong_type, owner, path, expected, got) | acc]
  end

  defp object(json, module, acc) do
    owner = inspect(module)
    fields = module.__schema__(:fields)
    {required, nullable} = rules(module)
    known = MapSet.new(fields, fn {_, name, _} -> name end)

    acc =
      Enum.reduce(fields, acc, fn {_field, name, type}, acc ->
        case Map.fetch(json, name) do
          {:ok, nil} when is_list(nullable) ->
            if name in nullable,
              do: acc,
              else: [finding(:unexpected_null, owner, name, nil, "null") | acc]

          {:ok, value} ->
            walk(value, type, owner, name, acc)

          :error when is_list(required) ->
            if name in required,
              do: [finding(:missing_required, owner, name, nil, nil) | acc],
              else: acc

          :error ->
            acc
        end
      end)

    additional = additional(module)

    json
    |> Enum.reject(fn {name, _} -> MapSet.member?(known, name) end)
    |> Enum.sort()
    |> Enum.reduce(acc, fn {name, value}, acc ->
      # Keys the spec allows with additionalProperties are documented.
      if additional,
        do: walk(value, additional, owner, name, acc),
        else: [finding(:undocumented_field, owner, name, nil, json_type(value)) | acc]
    end)
  end

  # SDKs generated before drift checking existed don't say which fields are
  # required or nullable: those checks are skipped for them.
  defp rules(module) do
    {module.__schema__(:required), module.__schema__(:nullable)}
  rescue
    FunctionClauseError -> {nil, nil}
  end

  defp additional(module) do
    module.__schema__(:additional)
  rescue
    FunctionClauseError -> nil
  end

  defp unknown_tag(json, {property, mapping}, owner, path, acc) when is_map(json) do
    case Map.get(json, property) do
      tag when is_binary(tag) and not is_map_key(mapping, tag) ->
        at = if path == "", do: property, else: path <> "." <> property
        [finding(:unknown_variant, owner, at, nil, tag) | acc]

      _ ->
        acc
    end
  end

  defp unknown_tag(_json, _discriminator, _owner, _path, acc), do: acc

  defp finding(kind, owner, path, expected, got),
    do: %{kind: kind, schema: owner, path: path, expected: expected, got: got}

  defp expected_type(:string), do: "string"
  defp expected_type(:integer), do: "integer"
  defp expected_type(:number), do: "number"
  defp expected_type(:boolean), do: "boolean"
  defp expected_type(:null), do: "null"
  defp expected_type({:array, _}), do: "array"
  defp expected_type({:map, _}), do: "object"
  defp expected_type(_), do: nil

  defp enum_type([value | _]), do: json_type(value)
  defp enum_type([]), do: nil

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  @doc false
  def json_type(nil), do: "null"
  def json_type(value) when is_boolean(value), do: "boolean"
  def json_type(value) when is_integer(value), do: "integer"
  def json_type(value) when is_number(value), do: "number"
  def json_type(value) when is_binary(value), do: "string"
  def json_type(value) when is_list(value), do: "array"
  def json_type(value) when is_map(value), do: "object"
  def json_type(_value), do: "unknown"

  ## Recording

  @doc """
  Whether a call with this config is checked: the config's `drift` setting,
  else `config :infusion_runtime, drift: ...`. `true`, `false`, or the
  share of calls to check (`0.01`).
  """
  @spec enabled?(map) :: boolean
  def enabled?(config) do
    setting =
      case Map.get(config, :drift) do
        nil -> Application.get_env(:infusion_runtime, :drift, false)
        value -> value
      end

    case setting do
      true -> true
      rate when is_number(rate) and rate > 0 -> :rand.uniform() <= rate
      _ -> false
    end
  end

  @doc """
  Checks `json` against `type`, records the findings under `operation`
  (`"GET /repos/{owner}/{repo}"`) and emits the telemetry event. Never
  raises: a bug here must not break the API call it watches.
  """
  @spec observe(term, term, String.t()) :: [finding]
  def observe(json, type, operation) do
    findings = check(json, type)

    if findings != [] do
      record(findings, operation)

      :telemetry.execute([:infusion, :drift], %{count: length(findings)}, %{
        operation: operation,
        findings: findings
      })
    end

    findings
  rescue
    _ -> []
  end

  defp record(findings, operation) do
    if :ets.whereis(@table) != :undefined do
      for f <- Enum.uniq(findings) do
        key = {f.kind, f.schema, f.path, f.expected, f.got, operation}

        if :ets.member(@table, key) or :ets.info(@table, :size) < @max_findings,
          do: :ets.update_counter(@table, key, {2, 1}, {key, 0})
      end
    end

    :ok
  end

  @doc """
  What was seen so far, most frequent first: one entry per finding with its
  `count` and the `operations` it was seen in.
  """
  @spec report() :: [map]
  def report do
    if :ets.whereis(@table) == :undefined do
      []
    else
      @table
      |> :ets.tab2list()
      |> Enum.group_by(fn {{kind, schema, path, expected, got, _op}, _n} ->
        {kind, schema, path, expected, got}
      end)
      |> Enum.map(fn {{kind, schema, path, expected, got}, rows} ->
        %{
          kind: kind,
          schema: schema,
          path: path,
          expected: expected,
          got: got,
          count: rows |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
          operations: rows |> Enum.map(fn {key, _} -> elem(key, 5) end) |> Enum.sort()
        }
      end)
      |> Enum.sort_by(&{-&1.count, &1.schema || "", &1.path, Atom.to_string(&1.kind)})
    end
  end

  @doc """
  Writes the report to `path` as JSON, the input of `mix infusion.drift`.
  """
  @spec export(Path.t()) :: :ok
  def export(path) do
    json = %{
      "infusion_drift" => 1,
      "runtime" => to_string(Application.spec(:infusion_runtime, :vsn) || ""),
      "findings" =>
        Enum.map(report(), fn f ->
          Map.new(f, fn {k, v} -> {Atom.to_string(k), json_value(v)} end)
        end)
    }

    File.write!(path, Jason.encode_to_iodata!(json, pretty: true))
  end

  defp json_value(v) when is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v)
  defp json_value(v), do: v

  @doc "Forgets everything seen so far."
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  The report as text, for IEx: `IO.puts(Infusion.Runtime.Drift.format())`.
  """
  @spec format([map]) :: String.t()
  def format(report \\ report()) do
    if report == [] do
      "No drift seen: every checked response matched the spec."
    else
      lines =
        Enum.map(report, fn f ->
          where = if f.schema, do: "#{f.schema}.#{f.path}", else: f.path

          "  #{String.pad_trailing(Atom.to_string(f.kind), 19)} #{where}#{detail(f)}  (#{f.count}x)"
        end)

      Enum.join(["#{length(report)} disagreements with the spec:" | lines], "\n")
    end
  end

  defp detail(%{kind: :wrong_type, expected: e, got: g}), do: ": spec says #{e}, got #{g}"
  defp detail(%{kind: :undocumented_field, got: g}), do: " (#{g})"

  defp detail(%{kind: kind, got: g}) when kind in [:unknown_enum, :unknown_variant],
    do: ": #{inspect(g)}"

  defp detail(%{kind: :unmatched_union, got: g}), do: ": #{g} fits no variant"
  defp detail(_), do: ""

  @doc false
  def kinds, do: @kinds
end
