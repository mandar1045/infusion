defmodule Infusion.Gen.Operations do
  @moduledoc """
  Generates one module per resource with one function per operation.

      defmodule OpenAI.Models do
        @retrieve_operation %{method: :get, path: "/models/{model}", ...}

        @spec retrieve(String.t(), keyword()) :: {:ok, OpenAI.Schemas.Model.t()} | {:error, Infusion.Runtime.Error.t()}
        def retrieve(model, opts \\\\ []), do: OpenAI.__request__(@retrieve_operation, [model], %{}, opts)

        def retrieve!(model, opts \\\\ []), do: ...
      end

  Path parameters are positional. Query, header and body parameters are one
  map or keyword list, `params`; operations that take none have no `params`
  argument. Call options (`timeout:`, `max_retries:`, `raw:`, ...) come last.
  The operation itself is data handed to `Infusion.Runtime.Request`.
  """

  alias Infusion.IR
  alias Infusion.IR.{Operation, Schema}
  alias Infusion.Gen.{Schemas, Source}
  alias Infusion.Naming

  # Words that can't name a function or a variable. Every other name works,
  # because generated modules never call their own functions unqualified.
  @reserved ~w(and or not in fn do end catch rescue after else when true false nil)

  @doc """
  Renders the operations of `ir` under `base` (`"OpenAI"`), with `modules`
  the schema-name-to-module mapping, both from `Infusion.Gen.Schemas.prepare/2`.
  """
  @spec render(%IR{}, String.t(), %{String.t() => String.t()}) :: [Schemas.file()]
  def render(%IR{} = ir, base, modules) do
    default_server = server_url(List.first(ir.servers))

    ir.operations
    |> Enum.group_by(&group_module(&1, base))
    |> Enum.sort()
    |> Enum.map(fn {module, operations} ->
      %{
        module: module,
        path: path(module),
        source: module_source(module, operations, base, ir, modules, default_server)
      }
    end)
  end

  @doc false
  def group_module(%Operation{module: parts}, base) do
    parts =
      case parts do
        [] -> ["Default"]
        # Schemas live under Base.Schemas.
        ["Schemas" | rest] -> ["SchemasResource" | rest]
        parts -> parts
      end

    Enum.join([base | parts], ".")
  end

  # lib/openai/fine_tuning/jobs.ex: the base module's directory is its
  # package name, the rest follow Elixir's convention.
  defp path(module) do
    [base | rest] = String.split(module, ".")

    "lib/" <>
      Enum.map_join([Naming.package(base) | Enum.map(rest, &Naming.function_name/1)], "/", & &1) <>
      ".ex"
  end

  @doc false
  def server_url(nil), do: nil

  def server_url(%{url: url, variables: variables}) do
    Enum.reduce(variables, url, fn {name, var}, acc ->
      String.replace(acc, "{#{name}}", to_string((is_map(var) && var["default"]) || ""))
    end)
  end

  ## Modules

  defp module_source(module, operations, base, ir, modules, default_server) do
    # _stream and _all variants must not take the name of another operation.
    taken = MapSet.new(operations, &safe(&1.function))

    functions =
      operations
      |> Enum.sort_by(& &1.function)
      |> Enum.map_join("\n\n", &function_source(&1, base, ir, modules, default_server, taken))

    names =
      operations |> Enum.map(&safe(&1.function)) |> Enum.sort() |> Enum.map_join(", ", &"`#{&1}`")

    """
    defmodule #{module} do
      @moduledoc #{Source.doc("API calls: #{names}.")}

      #{functions}
    end
    """
    |> format()
  end

  defp function_source(op, base, ir, modules, default_server, taken) do
    name = safe(op.function)
    path_vars = path_vars(op.path_params)
    params = params(op, ir)
    takes_params? = params != [] or op.body != nil
    response = response(op)
    stream = stream(op, ir)
    paginate = if stream == nil, do: Infusion.Gen.Pagination.detect(op, ir)
    paginate = paginate && Map.put(paginate, :id, watch_id(paginate.item, ir))
    stream_name = variant(name, "stream", taken)
    all_name = variant(name, "all", taken)
    watch_name = variant(name, "watch", taken)

    args = path_vars ++ if(takes_params?, do: ["params \\\\ %{}"], else: []) ++ ["opts \\\\ []"]
    call_params = if takes_params?, do: "params", else: "%{}"

    specs =
      Enum.map(op.path_params, &Schemas.typespec(&1.schema, modules)) ++
        if(takes_params?, do: ["map() | keyword()"], else: []) ++ ["keyword()"]

    result_spec =
      case response do
        nil -> "nil"
        {:json, schema} -> Schemas.typespec(schema, modules)
        :binary -> "binary()"
      end

    server = server_url(List.first(op.servers))

    operation =
      %{
        id: op.id,
        method: op.method,
        path: op.path,
        path_params: Enum.map(op.path_params, & &1.name),
        client_path_params: if(op.client_path_params != [], do: op.client_path_params),
        params: params,
        body: body_type(op.body),
        server: if(server != default_server, do: server),
        stream_param: stream && stream.param
      }
      |> Map.merge(content_type(op.body))

    attribute = "@#{name}_operation"

    call =
      "#{base}.__request__(#{attribute}, [#{Enum.join(path_vars, ", ")}], #{call_params}, opts)"

    arity = length(args)
    deprecated = if op.deprecated?, do: "@deprecated #{lit("Deprecated by the API.")}\n", else: ""
    spec_args = Enum.join(specs, ", ")
    return = "{:ok, #{result_spec}} | {:error, Infusion.Runtime.Error.t()}"

    head = """
    #{attribute} #{operation_literal(operation, response, stream, paginate, modules)}

    @doc #{doc(op, params, ir, stream, paginate, stream_name, all_name)}
    """

    stream_call = String.replace(call, ".__request__(", ".__stream__(")
    all_call = String.replace(call, ".__request__(", ".__paginate__(")
    watch_call = String.replace(call, ".__request__(", ".__watch__(")
    enum_spec = "{:ok, Enumerable.t()} | {:error, Infusion.Runtime.Error.t()}"
    args = Enum.join(args, ", ")

    # name, its result spec, the bang's spec, the call, and the doc (nil:
    # the doc of the operation, given above)
    defs =
      cond do
        # Only an event stream comes back: the function itself streams.
        stream && response == nil ->
          [{name, enum_spec, "Enumerable.t()", stream_call, nil}]

        stream ->
          event = Schemas.typespec(stream.schema, modules)

          [
            {name, return, result_spec, call, nil},
            {stream_name, enum_spec, "Enumerable.t()", stream_call,
             "Like `#{name}/#{arity}`, but streams the response: returns a lazy stream of `#{event}` events.\n\nRead it in the process that called this; stopping early closes the connection. An error the API sends mid-stream is raised as `Infusion.Runtime.Error`."}
          ]

        paginate ->
          item = Schemas.typespec(paginate.item, modules)

          [
            {name, return, result_spec, call, nil},
            {all_name, enum_spec, "Enumerable.t()", all_call,
             "Like `#{name}/#{arity}`, but returns every item, from every page: a lazy stream of `#{item}` that fetches pages as it is read.\n\nThe first page is fetched right away, so its errors are returned; a later page that fails raises `Infusion.Runtime.Error`. Stopping early (`Enum.take/2`) fetches no more pages."},
            {watch_name, "{:ok, pid()} | {:error, Infusion.Runtime.Error.t()}", "pid()",
             watch_call,
             "Watches this list and sends what changes: starts a process, linked to the caller, that polls it (with `ETag`s, so unchanged pages cost a `304`) and sends `{:infusion_watch, pid, %Infusion.Runtime.Watch.Event{}}` for every #{item} created, updated, deleted, or that moved into view (`:entered`).\n\nOptions: `every:` (milliseconds, default 30 seconds), `to:` (a pid, `{:pubsub, MyApp.PubSub, topic}` or a function), `pages:`, `initial:`, `ignore:`, plus any setting of `Infusion.Runtime.Config`. See `Infusion.Runtime.Watch`."}
          ]

        true ->
          [{name, return, result_spec, call, nil}]
      end

    sources =
      Enum.map(defs, fn {fun, spec, bang_spec, fun_call, fun_doc} ->
        doc = if fun_doc, do: "@doc #{Source.doc(fun_doc)}\n", else: ""

        """
        #{doc}#{deprecated}@spec #{fun}(#{spec_args}) :: #{spec}
        def #{fun}(#{args}), do: #{fun_call}

        @doc #{lit("Like `#{fun}/#{arity}`, but returns the #{if spec == return, do: "result", else: "stream"} or raises `Infusion.Runtime.Error`.")}
        #{deprecated}@spec #{fun}!(#{spec_args}) :: #{bang_spec}
        def #{fun}!(#{args}), do: Infusion.Runtime.Request.unwrap!(#{fun_call})
        """
      end)

    head <> Enum.join(sources, "\n")
  end

  # The JSON field that identifies a list item, for watching: the first of
  # these the item has (Twilio's items have a `sid`, not an `id`).
  @id_fields ~w(id sid uuid key node_id slug name)
  defp watch_id(item, ir) do
    names = item |> object_fields(ir, 0) |> Enum.map(& &1.name)
    Enum.find(@id_fields, &(&1 in names))
  end

  # name_stream, name_all, unless another operation of the module has that name.
  defp variant(name, suffix, taken) do
    candidate = "#{name}_#{suffix}"
    if MapSet.member?(taken, candidate), do: unique(candidate, taken), else: candidate
  end

  # The operation map, with the response type written as a descriptor
  # (module names in it are code, not strings).
  defp operation_literal(operation, response, stream, paginate, modules) do
    descriptor =
      case response do
        {:json, schema} -> Schemas.descriptor(schema, modules)
        _ -> "nil"
      end

    stream_descriptor =
      if stream,
        do: [", stream_response: " <> Schemas.descriptor(stream.schema, modules)],
        else: []

    paginate_literal =
      if paginate do
        rest =
          paginate
          |> Map.drop([:item])
          |> Enum.reject(fn {_k, v} -> v == nil end)
          |> Enum.sort()
          |> Enum.map(fn {k, v} -> "#{k}: #{lit(v)}" end)

        [
          ", paginate: %{" <>
            Enum.join(rest ++ ["item: " <> Schemas.descriptor(paginate.item, modules)], ", ") <>
            "}"
        ]
      else
        []
      end

    fields =
      operation
      |> Enum.reject(fn {_k, v} -> v == nil end)
      |> Enum.sort_by(fn {k, _} ->
        Enum.find_index(
          ~w(id method path path_params client_path_params params body content_type server stream_param)a,
          &(&1 == k)
        )
      end)
      |> Enum.map(fn {k, v} -> "#{k}: #{lit(v)}" end)

    "%{" <>
      Enum.join(fields ++ ["response: #{descriptor}"], ", ") <>
      Enum.join(stream_descriptor) <> Enum.join(paginate_literal) <> "}"
  end

  ## Parameters

  defp path_vars(params) do
    {vars, _} =
      Enum.map_reduce(params, MapSet.new(["params", "opts"]), fn p, taken ->
        var = unique(safe(p.field), taken)
        {var, MapSet.put(taken, var)}
      end)

    vars
  end

  # [{key, wire_name, location}] for query, header and top-level body
  # parameters. A key already taken gets its location appended.
  defp params(op, ir) do
    query = Enum.map(op.query_params, &{&1.field, &1.name, :query})
    headers = Enum.map(op.header_params, &{&1.field, &1.name, :header})

    body =
      for f <- body_fields(op.body, ir), body_type(op.body) in [:json, :form, :multipart] do
        {f.field, f.name, :body}
      end

    {params, _} =
      Enum.map_reduce(query ++ headers ++ body, MapSet.new(), fn {key, name, where}, taken ->
        key = if MapSet.member?(taken, key), do: unique("#{key}_#{where}", taken), else: key
        {{String.to_atom(key), name, where}, MapSet.put(taken, key)}
      end)

    params
  end

  defp body_fields(nil, _ir), do: []
  defp body_fields(%IR.Body{schema: schema}, ir), do: object_fields(schema, ir, 0)

  defp object_fields(%Schema{kind: :object, fields: fields}, _ir, _depth), do: fields

  defp object_fields(%Schema{kind: :ref, ref: ref}, ir, depth) when depth < 5 do
    case ir.schemas[ref] do
      nil -> []
      schema -> object_fields(schema, ir, depth + 1)
    end
  end

  defp object_fields(_schema, _ir, _depth), do: []

  defp body_type(nil), do: nil

  defp body_type(%IR.Body{content_type: type}) do
    cond do
      type == "application/x-www-form-urlencoded" -> :form
      String.starts_with?(type, "multipart/") -> :multipart
      type == "application/json" or String.ends_with?(type, "+json") -> :json
      true -> :binary
    end
  end

  defp content_type(%IR.Body{content_type: type})
       when type not in ["application/json", "application/x-www-form-urlencoded"] do
    if String.starts_with?(type, "multipart/"), do: %{}, else: %{content_type: type}
  end

  defp content_type(_body), do: %{}

  # The success response: {:json, schema}, :binary, or nil (no body).
  defp response(%Operation{responses: responses}) do
    success =
      responses
      |> Enum.filter(fn {status, _} -> is_binary(status) and String.starts_with?(status, "2") end)
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))

    case Enum.find(success, & &1.schema) || List.first(success) do
      nil -> nil
      %{schema: nil, content_type: nil} -> nil
      %{schema: nil, content_type: "text/event-stream"} -> nil
      %{schema: nil} -> :binary
      %{content_type: type, schema: schema} -> if json?(type), do: {:json, schema}, else: :binary
    end
  end

  defp json?(type), do: type == "application/json" or String.ends_with?(type || "", "+json")

  # How an operation that can answer with Server-Sent Events streams:
  # %{schema: event schema, param: how to ask for the stream}, or nil.
  # OpenAI asks with `stream: true` in the body (or the query), and its
  # speech endpoint with `stream_format: "sse"`.
  defp stream(%Operation{streaming?: false}, _ir), do: nil

  defp stream(%Operation{} = op, ir) do
    response =
      op.responses
      |> Enum.filter(fn {status, r} ->
        is_binary(status) and String.starts_with?(status, "2") and r.streaming?
      end)
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))
      |> List.first()

    fields = Map.new(body_fields(op.body, ir), &{&1.name, &1})

    param =
      cond do
        Map.has_key?(fields, "stream") -> {"stream", true}
        Enum.any?(op.query_params, &(&1.name == "stream")) -> {"stream", true}
        sse_format?(fields["stream_format"], ir) -> {"stream_format", "sse"}
        true -> nil
      end

    %{schema: (response && response.stream_schema) || %Schema{kind: :any}, param: param}
  end

  defp sse_format?(nil, _ir), do: false

  defp sse_format?(%{schema: schema}, ir) do
    case schema do
      %Schema{kind: :enum, values: values} -> "sse" in values
      %Schema{kind: :ref, ref: ref} -> sse_format?(%{schema: ir.schemas[ref] || %Schema{}}, ir)
      _ -> false
    end
  end

  ## Docs

  defp doc(op, params, ir, stream, paginate, stream_name, all_name) do
    summary = String.trim(op.summary || "")
    description = String.trim(op.description || "")
    description = if description == summary, do: "", else: description

    path_docs = Enum.map(op.path_params, &param_doc(safe(&1.field), &1.description, true))

    client_docs =
      for {name, setting} <- op.client_path_params do
        "`{#{name}}` in the path is the `#{inspect(setting)}` setting; pass `#{setting}: \"...\"` as an option to use another."
      end

    by_name = Map.new(op.query_params ++ op.header_params, &{&1.name, &1})
    fields = Map.new(body_fields(op.body, ir), &{&1.name, &1})

    param_docs =
      Enum.map(params, fn {key, name, where} ->
        source = if where == :body, do: fields[name], else: by_name[name]
        param_doc(Atom.to_string(key), source && source.description, source && source.required?)
      end)

    sections = [
      summary,
      description,
      "`#{op.method |> Atom.to_string() |> String.upcase()} #{op.path}`",
      section("Path parameters", path_docs),
      Enum.join(client_docs, "\n\n"),
      section("Parameters", param_docs),
      stream_doc(op, stream, stream_name),
      if(paginate, do: "To read every item across all pages, use `#{all_name}`.", else: "")
    ]

    sections |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n") |> Source.doc()
  end

  defp stream_doc(_op, nil, _name), do: ""

  defp stream_doc(op, %{param: param}, stream_name) do
    asks =
      case param do
        {name, value} -> " It sends `#{name}: #{inspect(value)}` for you."
        nil -> ""
      end

    if response(op) == nil,
      do: "Returns a lazy stream of events (Server-Sent Events).#{asks}",
      else: "To stream the response as it is generated, use `#{stream_name}`.#{asks}"
  end

  defp section(_title, []), do: ""
  defp section(title, lines), do: "## #{title}\n\n" <> Enum.join(lines, "\n")

  defp param_doc(name, description, required?) do
    desc = (description || "") |> String.replace(~r/\s+/, " ") |> String.trim()
    req = if required?, do: " (required)", else: ""
    "  * `#{name}`#{req}#{if desc == "", do: "", else: " - " <> desc}"
  end

  ## Helpers

  defp safe(name) when name in @reserved, do: name <> "_"
  defp safe(name), do: name

  defp unique(name, taken, n \\ 2) do
    cond do
      not MapSet.member?(taken, name) -> name
      not MapSet.member?(taken, "#{name}_#{n}") -> "#{name}_#{n}"
      true -> unique(name, taken, n + 1)
    end
  end

  defp lit(term), do: Source.lit(term)
  defp format(source), do: Source.format(source)
end
