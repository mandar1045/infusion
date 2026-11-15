defmodule Infusion.Gen.Schemas do
  @moduledoc """
  Generates one module per named schema.

  Objects become structs:

      defmodule OpenAI.Schemas.ChatCompletion do
        @moduledoc "..."
        defstruct [:id, :choices, ..., __extra__: %{}, __present__: []]
        @type t :: %__MODULE__{id: String.t(), choices: [OpenAI.Schemas.Choice.t()], ...}
        def __schema__(:fields), do: [{:id, "id", :string}, ...]
        def decode(json), do: Infusion.Runtime.Schema.decode_module(json, __MODULE__)
      end

  Other schemas (enums, unions, arrays, scalars) get a module with a type,
  so every reference works the same way. Decoding itself lives in
  `infusion_runtime`; the generated code only describes the fields.
  """

  alias Infusion.IR
  alias Infusion.IR.Schema
  alias Infusion.Naming
  alias Infusion.Gen.Source

  @type file :: %{module: String.t(), path: String.t(), source: String.t()}

  @doc """
  Renders every schema of `ir` under `base` (`"OpenAI"`). Returns the files
  and the schema-name-to-module mapping. Same as `prepare/2` followed by
  `render/3`.
  """
  @spec render(%IR{}, String.t()) :: {[file], %{String.t() => String.t()}}
  def render(%IR{} = ir, base) do
    {ir, modules} = prepare(ir, base)
    {render(ir, base, modules), modules}
  end

  @doc """
  Gives every object with fields a module: named schemas, objects written
  inline inside them, and objects written inline in an operation's success
  response or event stream (Stripe's `GET /v1/customers` answers an inline
  list object, which becomes `Stripe.Schemas.CustomersListResponse`).

  Returns the IR with those inline objects replaced by references, so every
  later step (operations, pagination) sees the same types, and the
  schema-name-to-module mapping.

  Options: `schema_names: :last_segment` names a dotted schema
  (`api.v2010.account.message`) by its last part (`Message`) when that is
  unique; `:full` (the default) uses the whole name.
  """
  @spec prepare(%IR{}, String.t(), keyword) :: {%IR{}, %{String.t() => String.t()}}
  def prepare(%IR{schemas: schemas} = ir, base, opts \\ []) do
    modules = module_names(Map.keys(schemas), base, opts[:schema_names] || :full)
    # The module mapping travels with the set of names taken, which would be
    # slow to rebuild for every inline object (Cloudflare has 15,000).
    names = {modules, MapSet.new(Map.values(modules))}
    {operations, {new, names}} = lift_operations(ir.operations, base, names)
    {schemas, {modules, _taken}} = extract_inline(Enum.into(new, schemas), names)
    {%{ir | schemas: schemas, operations: operations}, modules}
  end

  @doc """
  Renders the schemas of an IR made by `prepare/2`, with its module mapping.
  """
  @spec render(%IR{}, String.t(), %{String.t() => String.t()}) :: [file]
  def render(%IR{schemas: schemas}, base, modules) do
    dir = "lib/" <> Naming.package(base) <> "/schemas/"

    # File names come from the (unique) module names, not the schema names:
    # Cloudflare has schemas that differ only in punctuation.
    {files, _taken} =
      schemas
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_reduce(MapSet.new(), fn {name, schema}, taken ->
        module = Map.fetch!(modules, name)

        file =
          module
          |> String.split(".")
          |> List.last()
          |> Naming.function_name()
          |> unique_field(taken, 2)

        source = module_source(module, schema, modules)
        {%{module: module, path: dir <> file <> ".ex", source: source}, MapSet.put(taken, file)}
      end)

    files
  end

  # Inline objects in success responses and event streams become schemas
  # named after the operation: Pets.list answers PetsListResponse, a list
  # of PetsListResponseItem, and streams PetsListEvent. Keys start with "#",
  # which no component name can.
  defp lift_operations(operations, base, names) do
    Enum.map_reduce(operations, {[], names}, fn op, acc ->
      prefix = Enum.map_join(op.module, &Naming.module_part/1) <> Naming.module_part(op.function)
      key = "#op:#{op.method} #{op.path}:"

      {responses, acc} =
        op.responses
        |> Enum.sort()
        |> Enum.map_reduce(acc, fn {status, r}, acc ->
          if is_binary(status) and String.starts_with?(status, "2") do
            {schema, acc} = lift_maybe(r.schema, base, prefix <> "Response", key <> status, acc)

            {stream, acc} =
              lift_maybe(r.stream_schema, base, prefix <> "Event", key <> status <> "~", acc)

            {{status, %{r | schema: schema, stream_schema: stream}}, acc}
          else
            {{status, r}, acc}
          end
        end)

      {%{op | responses: Map.new(responses)}, acc}
    end)
  end

  defp lift_maybe(nil, _base, _part, _key, acc), do: {nil, acc}

  defp lift_maybe(schema, base, part, key, acc),
    do: lift(schema, base <> ".Schemas", part, key, acc)

  # Inline objects (schemas written inside another, without a name) become
  # nested modules named after where they appear: the items of
  # `CreateChatCompletionResponse.choices` are
  # `CreateChatCompletionResponse.Choice`. Objects nested inside those are
  # extracted too. Inline objects without fields stay plain maps.
  defp extract_inline(schemas, names) do
    do_extract(Map.to_list(schemas), schemas, names)
  end

  defp do_extract([], schemas, names), do: {schemas, names}

  defp do_extract([{name, %Schema{kind: :object} = schema} | rest], schemas, names) do
    parent = Map.fetch!(elem(names, 0), name)

    {fields, {new, names}} =
      Enum.map_reduce(schema.fields, {[], names}, fn field, acc ->
        {s, acc} =
          lift(
            field.schema,
            parent,
            Naming.module_part(field.name),
            name <> "." <> field.name,
            acc
          )

        {%{field | schema: s}, acc}
      end)

    schemas = Map.put(schemas, name, %{schema | fields: fields})
    do_extract(new ++ rest, Enum.into(new, schemas), names)
  end

  defp do_extract([_ | rest], schemas, names), do: do_extract(rest, schemas, names)

  # Replaces inline objects inside `s` by references to new named schemas.
  defp lift(%Schema{kind: :object, fields: [_ | _]} = s, parent, part, key, acc) do
    {new, {modules, taken}} = acc
    module = unique("#{parent}.#{part}", taken, 2)
    ref = %Schema{kind: :ref, ref: key, nullable?: s.nullable?, description: s.description}
    names = {Map.put(modules, key, module), MapSet.put(taken, module)}
    {ref, {[{key, %{s | name: key}} | new], names}}
  end

  defp lift(%Schema{kind: :array, items: items} = s, parent, part, key, acc) do
    {items, acc} = lift(items, parent, singular(part), key <> "[]", acc)
    {%{s | items: items}, acc}
  end

  defp lift(%Schema{kind: :map, value: value} = s, parent, part, key, acc) do
    {value, acc} = lift(value, parent, part <> "Value", key <> "{}", acc)
    {%{s | value: value}, acc}
  end

  defp lift(%Schema{kind: :union, variants: variants} = s, parent, part, key, acc) do
    {variants, acc} =
      variants
      |> Enum.with_index(1)
      |> Enum.map_reduce(acc, fn {v, i}, acc ->
        lift(v, parent, "#{part}#{i}", "#{key}|#{i}", acc)
      end)

    {%{s | variants: variants}, acc}
  end

  defp lift(s, _parent, _part, _key, acc), do: {s, acc}

  defp singular(part) do
    cond do
      String.ends_with?(part, "ies") ->
        String.slice(part, 0..-4//1) <> "y"

      String.ends_with?(part, "sses") ->
        String.slice(part, 0..-3//1)

      String.ends_with?(part, "s") and not String.ends_with?(part, "ss") ->
        String.slice(part, 0..-2//1)

      true ->
        part <> "Item"
    end
  end

  # Schema names to unique module names: "chat.completion" and
  # "ChatCompletion" would both be ChatCompletion; the later gets a suffix.
  defp module_names(names, base, mode) do
    short = if mode == :last_segment, do: short_names(names), else: %{}

    {map, _} =
      names
      |> Enum.sort()
      |> Enum.reduce({%{}, MapSet.new()}, fn name, {map, taken} ->
        part = Map.get_lazy(short, name, fn -> Naming.module_part(name) end)
        part = unique(part, taken, 2)
        {Map.put(map, name, "#{base}.Schemas.#{part}"), MapSet.put(taken, part)}
      end)

    map
  end

  # "api.v2010.account.message" -> "Message", for the dotted names whose last
  # part no other schema (dotted or not) would also be called.
  defp short_names(names) do
    full = Map.new(names, &{&1, Naming.module_part(&1)})

    candidates =
      for name <- names, String.contains?(name, "."), into: %{} do
        {name, name |> String.split(".") |> List.last() |> Naming.module_part()}
      end

    counts =
      Enum.frequencies(
        Map.values(candidates) ++
          for({name, part} <- full, not Map.has_key?(candidates, name), do: part)
      )

    for {name, part} <- candidates, counts[part] == 1, into: %{}, do: {name, part}
  end

  defp unique(part, taken, n) do
    cond do
      not MapSet.member?(taken, part) -> part
      not MapSet.member?(taken, "#{part}#{n}") -> "#{part}#{n}"
      true -> unique(part, taken, n + 1)
    end
  end

  ## Modules

  defp module_source(module, %Schema{kind: :object} = schema, modules) do
    fields = field_names(schema.fields)

    struct_fields = Enum.map_join(fields, ", ", fn {f, _} -> ":#{f.field}" end)
    struct_fields = if struct_fields == "", do: "", else: struct_fields <> ", "

    types =
      Enum.map_join(fields, ",\n", fn {f, _} ->
        "#{f.field}: #{typespec(f.schema, modules)}#{if f.required? and not f.schema.nullable?, do: "", else: " | nil"}"
      end)

    types = if types == "", do: "", else: types <> ",\n"

    descriptors =
      Enum.map_join(fields, ",\n", fn {f, _} ->
        "{:#{f.field}, #{lit(f.name)}, #{descriptor(f.schema, modules)}}"
      end)

    """
    defmodule #{module} do
      @moduledoc #{doc(schema.description, fields)}

      @derive {Inspect, except: [:__extra__, :__present__]}
      defstruct [#{struct_fields}__extra__: %{}, __present__: []]

      @type t :: %__MODULE__{
        #{types}__extra__: %{optional(String.t()) => term()},
        __present__: [atom()]
      }

      @doc false
      def __schema__(:fields) do
        [#{descriptors}]
      end

      @doc "Decodes parsed JSON into this struct."
      @spec decode(term) :: t | term
      def decode(json), do: Infusion.Runtime.Schema.decode_module(json, __MODULE__)
    end
    """
    |> format()
  end

  defp module_source(module, schema, modules) do
    """
    defmodule #{module} do
      @moduledoc #{doc(schema.description, [])}

      @type t :: #{typespec(schema, modules)}

      @doc false
      def __schema__(:type), do: #{descriptor(schema, modules)}

      @doc "Decodes parsed JSON as this type."
      @spec decode(term) :: t | term
      def decode(json), do: Infusion.Runtime.Schema.decode_module(json, __MODULE__)
    end
    """
    |> format()
  end

  # Field names unique within the struct: "userId" and "user_id" both become
  # user_id. A property whose JSON name already is the field name keeps it;
  # the others get a suffix (user_id_2). Fields stay in JSON-name order.
  defp field_names(fields) do
    owners = Enum.sort_by(fields, &if(&1.field == &1.name, do: 0, else: 1))

    {names, _} =
      Enum.reduce(owners, {%{}, MapSet.new(["__extra__", "__present__"])}, fn f, {names, taken} ->
        name = unique_field(f.field, taken, 2)
        {Map.put(names, f.name, name), MapSet.put(taken, name)}
      end)

    Enum.map(fields, &{%{&1 | field: Map.fetch!(names, &1.name)}, nil})
  end

  defp unique_field(field, taken, n) do
    cond do
      not MapSet.member?(taken, field) -> field
      not MapSet.member?(taken, "#{field}_#{n}") -> "#{field}_#{n}"
      true -> unique_field(field, taken, n + 1)
    end
  end

  ## Types

  @doc false
  def descriptor(%Schema{kind: kind} = s, modules) do
    case kind do
      :ref ->
        "{:ref, #{ref_module(s.ref, modules)}}"

      :scalar ->
        ":" <> scalar(s.type)

      :enum ->
        "{:enum, #{lit(Enum.filter(s.values, &is_binary/1))}}"

      :const ->
        "{:const, #{lit(s.const)}}"

      :array ->
        "{:array, #{descriptor(s.items, modules)}}"

      :map ->
        "{:map, #{descriptor(s.value, modules)}}"

      :union ->
        "{:union, [#{Enum.map_join(s.variants, ", ", &descriptor(&1, modules))}], #{discriminator(s.discriminator, modules)}}"

      # Inline objects are plain maps for now.
      _ ->
        ":any"
    end
  end

  @doc false
  def typespec(%Schema{kind: kind} = s, modules) do
    case kind do
      :ref -> "#{ref_module(s.ref, modules)}.t()"
      :scalar -> scalar_spec(s.type)
      :enum -> "String.t()"
      :const when is_binary(s.const) -> "String.t()"
      :const -> "term()"
      :array -> "[#{typespec(s.items, modules)}]"
      :map -> "%{optional(String.t()) => #{typespec(s.value, modules)}}"
      :union -> s.variants |> Enum.map(&typespec(&1, modules)) |> Enum.uniq() |> Enum.join(" | ")
      :object -> "map()"
      _ -> "term()"
    end
  end

  defp scalar(type) when type in ~w(string integer number boolean null), do: type
  defp scalar(_), do: "any"

  defp scalar_spec("string"), do: "String.t()"
  defp scalar_spec("integer"), do: "integer()"
  defp scalar_spec("number"), do: "number()"
  defp scalar_spec("boolean"), do: "boolean()"
  defp scalar_spec("null"), do: "nil"
  defp scalar_spec(_), do: "term()"

  # A reference to a schema the spec doesn't define can't become a module.
  defp ref_module(name, modules), do: Map.get(modules, name, "Infusion.Runtime.Any")

  defp discriminator(nil, _modules), do: "nil"

  defp discriminator(%{property: prop, mapping: mapping}, modules) when map_size(mapping) > 0 do
    pairs =
      Enum.map_join(Enum.sort(mapping), ", ", fn {value, name} ->
        "#{lit(value)} => #{ref_module(name, modules)}"
      end)

    "{#{lit(prop)}, %{#{pairs}}}"
  end

  defp discriminator(_, _modules), do: "nil"

  ## Docs

  defp doc(description, fields) do
    text = String.trim(description || "")

    field_docs =
      for {f, _} <- fields do
        desc = (f.description || "") |> String.replace(~r/\s+/, " ") |> String.trim()

        name =
          if f.field == Naming.function_name(f.name) and f.field == f.name,
            do: "`#{f.field}`",
            else: "`#{f.field}` (`#{f.name}`)"

        "  * #{name}#{if desc == "", do: "", else: " - " <> desc}"
      end

    body =
      [text, if(field_docs == [], do: "", else: "## Fields\n\n" <> Enum.join(field_docs, "\n"))]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    Source.doc(body)
  end

  defp lit(term), do: Source.lit(term)
  defp format(source), do: Source.format(source)
end
