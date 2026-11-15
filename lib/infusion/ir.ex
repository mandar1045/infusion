defmodule Infusion.IR do
  @moduledoc """
  The intermediate representation: what the code generator reads, instead of
  the spec. Built from a document that went through `Infusion.Ref` and
  `Infusion.Normalize`.

      {:ok, ir} = Infusion.IR.build(document)
      ir.operations  #=> [%Infusion.IR.Operation{module: ["Repos"], function: "get", ...}]
      ir.schemas     #=> %{"Repository" => %Infusion.IR.Schema{kind: :object, ...}}
      ir.warnings    #=> what could not be represented
  """

  alias Infusion.{Naming, Ref}

  defstruct operations: [], schemas: %{}, servers: [], auth: nil, warnings: []

  defmodule Operation do
    @moduledoc "One API call."
    defstruct [
      :id,
      :module,
      :function,
      :naming,
      :method,
      :path,
      :servers,
      :summary,
      :description,
      :body,
      path_params: [],
      query_params: [],
      header_params: [],
      cookie_params: [],
      responses: %{},
      streaming?: false,
      deprecated?: false,
      # nil: detected by Infusion.Gen.Pagination; false or a setting: from infusion.exs
      pagination: nil
    ]
  end

  defmodule Param do
    @moduledoc "A path, query, header or cookie parameter."
    defstruct [
      :name,
      :field,
      :location,
      :schema,
      :description,
      required?: false,
      deprecated?: false
    ]
  end

  defmodule Body do
    @moduledoc "A request body: its preferred content type and the others accepted."
    defstruct [:content_type, :schema, :description, other_content_types: [], required?: false]
  end

  defmodule Response do
    @moduledoc """
    A response for one status (or `:default`). `schema` is the body's schema
    (JSON preferred); a response that can also stream (`text/event-stream`)
    has `streaming?` set and the schema of each event in `stream_schema`.
    """
    defstruct [:status, :content_type, :schema, :stream_schema, :description, streaming?: false]
  end

  defmodule Schema do
    @moduledoc """
    A schema, classified.

    `kind` is one of `:object`, `:map` (string keys to `value`), `:array`
    (`items`), `:union` (`variants`, `discriminator`), `:enum` (`values`),
    `:scalar` (`type`, `format`), `:ref` (`ref` names a schema), `:const`,
    or `:any`.
    """
    defstruct [
      :kind,
      :name,
      :type,
      :format,
      :ref,
      :items,
      :value,
      :discriminator,
      :description,
      :const,
      fields: [],
      variants: [],
      values: [],
      nullable?: false,
      deprecated?: false,
      extra_fields?: false
    ]
  end

  defmodule Field do
    @moduledoc "A property of an object schema."
    defstruct [
      :name,
      :field,
      :schema,
      :description,
      required?: false,
      deprecated?: false,
      read_only?: false,
      write_only?: false
    ]
  end

  @methods ~w(get put post delete patch head options)
  @body_preference [
    "application/json",
    "application/x-www-form-urlencoded",
    "multipart/form-data"
  ]

  @doc "Builds the IR. Never fails on unusual schemas: they become `:any`, with a warning."
  @spec build(map) :: {:ok, %__MODULE__{}}
  def build(document) do
    Process.put({__MODULE__, :warnings}, [])

    schemas =
      for {name, schema} <- get_in(document, ["components", "schemas"]) || %{}, into: %{} do
        {name, %{schema(schema, "components.schemas.#{name}") | name: name}}
      end

    paths = document["paths"] || %{}
    collections = collections(Map.keys(paths))

    operations =
      for {path, item} <- paths,
          is_map(item),
          {method, op} <- item,
          method in @methods,
          is_map(op) do
        operation(op, path, method, item, collections)
      end
      |> Enum.sort_by(&{&1.module, &1.function})
      |> disambiguate()

    warnings = Process.delete({__MODULE__, :warnings}) |> Enum.reverse()

    {:ok,
     %__MODULE__{
       operations: operations,
       schemas: schemas,
       servers: servers(document["servers"]),
       auth: auth(document),
       warnings: warnings
     }}
  end

  ## Operations

  defp operation(op, path, method, item, collections) do
    methods = for {m, %{}} <- item, m in @methods, do: m
    name = Naming.operation(op, path, method, methods: methods, collections: collections)
    where = "#{String.upcase(method)} #{path}"
    params = Enum.map((item["parameters"] || []) ++ (op["parameters"] || []), &param(&1, where))
    # An operation-level parameter replaces a path-level one with the same name and location.
    params = params |> Enum.reverse() |> Enum.uniq_by(&{&1.name, &1.location}) |> Enum.reverse()
    by_location = Enum.group_by(params, & &1.location)
    responses = responses(op["responses"] || %{}, where)

    %Operation{
      id: op["operationId"],
      module: name.module,
      function: name.function,
      naming: name.strategy,
      method: String.to_atom(method),
      path: path,
      servers: servers(op["servers"] || item["servers"]),
      summary: op["summary"],
      description: op["description"],
      body: body(op["requestBody"], where),
      path_params: order_path_params(Map.get(by_location, :path, []), path),
      query_params: Map.get(by_location, :query, []),
      header_params: Map.get(by_location, :header, []),
      cookie_params: Map.get(by_location, :cookie, []),
      responses: responses,
      streaming?: Enum.any?(responses, fn {_, r} -> r.streaming? end),
      deprecated?: op["deprecated"] == true
    }
  end

  # Paths with items under them: "/things" when "/things/{id}" exists.
  defp collections(paths) do
    for path <- paths,
        segments = path |> Naming.path_only() |> String.split("/"),
        String.starts_with?(List.last(segments), "{"),
        into: MapSet.new(),
        do: segments |> Enum.drop(-1) |> Enum.join("/")
  end

  defp param(p, where) do
    location =
      case p["in"] do
        "path" ->
          :path

        "query" ->
          :query

        "header" ->
          :header

        "cookie" ->
          :cookie

        other ->
          warn(
            "#{where}: parameter #{inspect(p["name"])} has an unknown location #{inspect(other)}"
          )

          :query
      end

    schema =
      case p do
        %{"schema" => s} ->
          schema(s, "#{where} parameter #{p["name"]}")

        %{"content" => content} ->
          content |> Map.values() |> List.first() |> Map.get("schema", %{}) |> schema(where)

        _ ->
          %Schema{kind: :any}
      end

    %Param{
      name: p["name"],
      field: Naming.function_name(p["name"] || "param"),
      location: location,
      schema: schema,
      description: p["description"],
      required?: location == :path or p["required"] == true,
      deprecated?: p["deprecated"] == true
    }
  end

  # Path parameters in the order they appear in the path.
  defp order_path_params(params, path) do
    order =
      Regex.scan(~r/\{([^}]+)\}/, path, capture: :all_but_first)
      |> List.flatten()
      |> Enum.with_index()
      |> Map.new()

    Enum.sort_by(params, &Map.get(order, &1.name, 999))
  end

  defp body(nil, _where), do: nil

  defp body(%{"content" => content} = rb, where) when is_map(content) and map_size(content) > 0 do
    types = Map.keys(content)

    preferred =
      Enum.find(@body_preference, &(&1 in types)) || Enum.find(types, &json?/1) ||
        hd(Enum.sort(types))

    %Body{
      content_type: preferred,
      other_content_types: List.delete(types, preferred),
      schema: schema(get_in(content, [preferred, "schema"]) || %{}, "#{where} body"),
      description: rb["description"],
      required?: rb["required"] == true
    }
  end

  defp body(_rb, _where), do: nil

  defp responses(responses, where) do
    for {status, r} <- responses, is_map(r), into: %{} do
      status = if status == "default", do: :default, else: status
      content = r["content"] || %{}
      types = Map.keys(content)
      streaming? = "text/event-stream" in types
      body_types = List.delete(types, "text/event-stream")
      preferred = Enum.find(body_types, &json?/1) || List.first(body_types)

      schema = content_schema(content, preferred, "#{where} response #{status}")

      stream_schema =
        if streaming?,
          do: content_schema(content, "text/event-stream", "#{where} stream #{status}")

      {status,
       %Response{
         status: status,
         content_type: preferred || (streaming? && "text/event-stream") || nil,
         schema: schema,
         stream_schema: stream_schema,
         description: r["description"],
         streaming?: streaming?
       }}
    end
  end

  defp content_schema(_content, nil, _where), do: nil

  defp content_schema(content, type, where) do
    case get_in(content, [type, "schema"]) do
      nil -> nil
      s -> schema(s, where)
    end
  end

  defp json?(type), do: type == "application/json" or String.ends_with?(type, "+json")

  # Two operations with the same module and function: the later ones get
  # their operation ID (or method) appended.
  defp disambiguate(operations) do
    {ops, _seen} =
      Enum.map_reduce(operations, MapSet.new(), fn op, seen ->
        key = {op.module, op.function}

        if MapSet.member?(seen, key) do
          renamed = %{op | function: alternative_name(op, seen)}

          warn(
            "#{Enum.join(op.module, ".")}.#{op.function} is taken; #{String.upcase(to_string(op.method))} #{op.path} is #{renamed.function}"
          )

          {renamed, MapSet.put(seen, {op.module, renamed.function})}
        else
          {op, MapSet.put(seen, key)}
        end
      end)

    ops
  end

  # The operation ID without the module's words (`listExternalStorageConfigurations`
  # in `ExternalStorage` is `list_configurations`), else the name with the ID
  # appended.
  defp alternative_name(op, seen) do
    id_name =
      op.id && Naming.drop_module_words(Naming.function_name(op.id), List.last(op.module) || "")

    suffixed = "#{op.function}_#{Naming.function_name(op.id || Atom.to_string(op.method))}"

    Enum.find([id_name, suffixed], &(&1 && not MapSet.member?(seen, {op.module, &1}))) ||
      "#{suffixed}_#{:erlang.phash2(op.path)}"
  end

  # How the API wants its credential: the first scheme the document requires,
  # else the first it defines. nil when the spec says nothing (GitHub).
  defp auth(document) do
    schemes = get_in(document, ["components", "securitySchemes"]) || %{}

    required =
      for requirement <- List.wrap(document["security"]),
          is_map(requirement),
          {name, _scopes} <- requirement,
          do: name

    name =
      Enum.find(required, &Map.has_key?(schemes, &1)) ||
        schemes |> Map.keys() |> Enum.sort() |> List.first()

    case schemes[name] do
      %{"type" => "http", "scheme" => scheme} when is_binary(scheme) ->
        case String.downcase(scheme) do
          "basic" -> :basic
          _ -> :bearer
        end

      %{"type" => "apiKey", "in" => "header", "name" => header} ->
        if String.downcase(header) == "authorization", do: :bearer, else: {:header, header}

      %{"type" => "apiKey", "in" => "query", "name" => param} ->
        {:query, param}

      %{"type" => type} when type in ["oauth2", "openIdConnect"] ->
        :bearer

      _ ->
        nil
    end
  end

  defp servers(nil), do: []

  defp servers(list) when is_list(list),
    do: Enum.map(list, &%{url: &1["url"], variables: &1["variables"] || %{}})

  ## Schemas

  @doc false
  def schema(%{"$ref" => ref} = s, _where) when is_binary(ref) do
    %Schema{
      kind: :ref,
      ref: Ref.schema_name(ref),
      nullable?: s["nullable"] == true,
      description: s["description"]
    }
  end

  def schema(s, where) when is_map(s) do
    base = %Schema{
      nullable?: s["nullable"] == true,
      deprecated?: s["deprecated"] == true,
      description: s["description"]
    }

    cond do
      Map.has_key?(s, "allOf") ->
        warn("#{where}: allOf that could not be merged is treated as any value")
        %{base | kind: :any}

      constraint_union?(s) ->
        # "oneOf: [{required: [a]}, {required: [b]}]" says which fields must
        # be present; it doesn't change the type.
        schema(Map.drop(s, ["oneOf", "anyOf"]), where)

      is_list(s["oneOf"]) or is_list(s["anyOf"]) ->
        variants =
          (s["oneOf"] || s["anyOf"])
          |> Enum.with_index()
          |> Enum.map(fn {v, i} -> schema(v, "#{where}.variant#{i}") end)

        %{
          base
          | kind: :union,
            variants: variants,
            discriminator: discriminator(s["discriminator"])
        }

      Map.has_key?(s, "const") ->
        %{base | kind: :const, const: s["const"], type: s["type"]}

      is_list(s["enum"]) ->
        %{base | kind: :enum, values: s["enum"], type: s["type"]}

      is_list(s["type"]) ->
        %{base | kind: :union, variants: Enum.map(s["type"], &schema(%{"type" => &1}, where))}

      s["type"] == "array" or Map.has_key?(s, "items") ->
        %{base | kind: :array, items: schema(s["items"] || %{}, "#{where}.items")}

      s["type"] == "object" or Map.has_key?(s, "properties") ->
        object(s, base, where)

      s["type"] in ~w(string integer number boolean null) ->
        %{base | kind: :scalar, type: s["type"], format: s["format"]}

      true ->
        unsupported =
          Map.keys(s) --
            ~w(description title nullable deprecated example examples default readOnly writeOnly externalDocs format)

        if Enum.any?(unsupported, &(not String.starts_with?(&1, "x-"))),
          do: warn("#{where}: unsupported keywords #{inspect(unsupported)}, treated as any value")

        %{base | kind: :any}
    end
  end

  def schema(true, _where), do: %Schema{kind: :any}

  def schema(_other, where) do
    warn("#{where}: not a schema, treated as any value")
    %Schema{kind: :any}
  end

  @constraint_keys ~w(required description title not minProperties maxProperties)
  defp constraint_union?(s) do
    variants = s["oneOf"] || s["anyOf"]

    is_list(variants) and variants != [] and
      Enum.all?(
        variants,
        &(is_map(&1) and map_size(&1) > 0 and Map.keys(&1) -- @constraint_keys == [])
      )
  end

  defp object(s, base, where) do
    required = s["required"] || []
    props = s["properties"] || %{}
    extra = s["additionalProperties"]

    cond do
      props == %{} and is_map(extra) and extra != %{} ->
        %{base | kind: :map, value: schema(extra, "#{where}.additionalProperties")}

      true ->
        fields =
          for {name, ps} <- Enum.sort_by(props, &elem(&1, 0)) do
            ps = if is_map(ps), do: ps, else: %{}

            %Field{
              name: name,
              field: Naming.function_name(name),
              schema: schema(ps, "#{where}.#{name}"),
              description: ps["description"],
              required?: name in required,
              deprecated?: ps["deprecated"] == true,
              read_only?: ps["readOnly"] == true,
              write_only?: ps["writeOnly"] == true
            }
          end

        %{base | kind: :object, fields: fields, extra_fields?: extra != false}
    end
  end

  defp discriminator(%{"propertyName" => prop} = d) do
    mapping =
      for {value, ref} <- d["mapping"] || %{},
          into: %{},
          do: {value, if(String.starts_with?(ref, "#"), do: Ref.schema_name(ref), else: ref)}

    %{property: prop, mapping: mapping}
  end

  defp discriminator(_), do: nil

  defp warn(message) do
    Process.put({__MODULE__, :warnings}, [message | Process.get({__MODULE__, :warnings}, [])])
    :ok
  end
end
