defmodule Infusion.RealSpecsTest do
  use ExUnit.Case, async: true
  alias Infusion.Spec

  @moduletag :specs
  @moduletag timeout: 120_000

  defp spec(name), do: Path.join(System.fetch_env!("INFUSION_SPECS"), name)

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {div(us, 1000), result}
  end

  test "OpenAI's YAML and JSON specs load into the same document" do
    {yaml_ms, {:ok, yaml}} = timed(fn -> Spec.load(spec("openai.yaml")) end)
    {json_ms, {:ok, json}} = timed(fn -> Spec.load(spec("openai.json")) end)

    assert yaml.version == "3.1.0"
    assert yaml.document == json.document
    assert json_ms < 2_000
    assert yaml_ms < 30_000
  end

  test "Cloudflare's 28 MB spec loads in seconds" do
    {ms, {:ok, spec}} = timed(fn -> Spec.load(spec("cloudflare.json")) end)
    assert map_size(spec.document["paths"]) > 2_000
    assert ms < 5_000
  end

  @specs ~w(openai.json stripe.json github.json cloudflare.json twilio_api.json)

  test "every reference in five real specs resolves, and only schema references remain" do
    for name <- @specs do
      {:ok, spec} = Spec.load(spec(name))
      {ms, result} = timed(fn -> Infusion.Ref.resolve(spec.document) end)
      assert {:ok, resolved} = result, "#{name}: #{inspect(result)}"

      leftover =
        resolved
        |> refs_outside_literals()
        |> Enum.reject(&Infusion.Ref.schema_ref?/1)

      assert leftover == [],
             "#{name} still has non-schema references: #{inspect(Enum.take(leftover, 3))}"

      assert ms < 15_000, "#{name} took #{ms} ms"
      IO.puts("  #{name}: resolved in #{ms} ms")
    end
  end

  test "five real specs normalize: no 3.1 null types left, allOf merged or explained" do
    for name <- @specs do
      {:ok, spec} = Spec.load(spec(name))
      {:ok, resolved} = Infusion.Ref.resolve(spec.document)
      {ms, {:ok, normalized, warnings}} = timed(fn -> Infusion.Normalize.run(resolved) end)

      null_types =
        count(normalized, fn m ->
          match?(%{"type" => t} when is_list(t), m) and "null" in m["type"]
        end)

      false_nullable = count(normalized, &match?(%{"nullable" => false}, &1))
      all_of_before = count(resolved, &Map.has_key?(&1, "allOf"))
      all_of_after = count(normalized, &Map.has_key?(&1, "allOf"))

      assert null_types == 0, "#{name}: #{null_types} type lists still contain null"
      assert false_nullable == 0
      assert ms < 20_000, "#{name} took #{ms} ms"

      kinds =
        warnings
        |> Enum.map(&(&1.message |> String.split(":") |> hd() |> String.slice(0, 45)))
        |> Enum.frequencies()

      IO.puts(
        "  #{name}: #{ms} ms, allOf #{all_of_before} -> #{all_of_after} left, " <>
          "#{length(warnings)} warnings #{inspect(kinds)}"
      )
    end
  end

  test "five real specs go through the whole pipeline into the IR" do
    for name <- @specs do
      {:ok, spec} = Spec.load(spec(name))
      {:ok, resolved} = Infusion.Ref.resolve(spec.document)
      {:ok, normalized, _} = Infusion.Normalize.run(resolved)
      {ms, {:ok, ir}} = timed(fn -> Infusion.IR.build(normalized) end)

      ops = ir.operations
      modules = ops |> Enum.map(& &1.module) |> Enum.uniq() |> length()
      strategies = Enum.frequencies_by(ops, & &1.naming)
      renamed = Enum.count(ir.warnings, &(&1 =~ "is taken"))
      unsupported = Enum.count(ir.warnings, &(&1 =~ "unsupported keywords"))
      kinds = ir.schemas |> Map.values() |> Enum.frequencies_by(& &1.kind)

      assert length(ops) > 100

      assert ops |> Enum.map(&{&1.module, &1.function}) |> Enum.uniq() |> length() == length(ops),
             "#{name}: duplicate names"

      assert ms < 10_000

      IO.puts(
        "  #{name}: #{ms} ms, #{length(ops)} ops in #{modules} modules, naming #{inspect(strategies)}, " <>
          "#{renamed} renamed, #{Enum.count(ops, & &1.streaming?)} streaming, schemas #{inspect(kinds)}, " <>
          "#{unsupported} unsupported, #{length(ir.warnings)} warnings"
      )
    end
  end

  # One test per spec: compiling Cloudflare's ~9,000 modules alone takes minutes.
  for {name, base} <- [
        {"openai.json", "OpenAI"},
        {"stripe.json", "Stripe"},
        {"github.json", "GitHub"},
        {"twilio_api.json", "Twilio"},
        {"cloudflare.json", "Cloudflare"}
      ] do
    @tag timeout: :infinity
    test "the whole #{name} SDK generates code that compiles without warnings" do
      compile_sdk!(unquote(name), unquote(base))

      if unquote(base) == "OpenAI" do
        decode_chat_completion!()
        call_chat_completion!()
      end
    end
  end

  defp compile_sdk!(name, base) do
    {gen_ms, {:ok, result}} = timed(fn -> Infusion.generate(spec(name), name: base) end)
    files = Enum.filter(result.files, &(&1.module && String.ends_with?(&1.path, ".ex")))

    dir =
      Path.join(System.tmp_dir!(), "infusion-gen-#{base}-#{System.unique_integer([:positive])}")

    # Removed even when an assertion fails: Cloudflare's SDK is 10,000 files.
    try do
      paths =
        for f <- files do
          path = Path.join(dir, f.path)
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, f.source)
          path
        end

      {compile_ms, compiled} =
        timed(fn -> Kernel.ParallelCompiler.compile(paths, return_diagnostics: true) end)

      assert {:ok, modules, %{compile_warnings: warnings}} = compiled, "#{name} did not compile"

      IO.puts(
        "  #{name}: #{length(result.ir.operations)} operations, #{length(files)} modules " <>
          "generated in #{gen_ms} ms, compiled in #{compile_ms} ms, #{length(warnings)} warnings"
      )

      # The compiler also returns the Inspect implementations @derive creates.
      sdk_modules =
        Enum.reject(modules, &String.starts_with?(Atom.to_string(&1), "Elixir.Inspect."))

      assert length(sdk_modules) == length(files)
      assert warnings == [], inspect(Enum.take(warnings, 3), pretty: true)
    after
      File.rm_rf!(dir)
    end
  end

  # The generated function, the runtime and Req, against a stub of the API.
  defp call_chat_completion! do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert conn.request_path == "/v1/chat/completions"
      assert %{"model" => "gpt-5.5", "messages" => [_]} = JSON.decode!(body)

      Req.Test.json(conn, %{
        "id" => "chatcmpl-2",
        "object" => "chat.completion",
        "created" => 1,
        "model" => "gpt-5.5",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "Hi"}
          }
        ]
      })
    end)

    chat = Module.concat(["OpenAI.Chat"])

    assert {:ok, response} =
             chat.create_completion(
               [model: "gpt-5.5", messages: [%{role: "user", content: "Hello"}]],
               api_key: "sk-test",
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert [%{message: %{content: "Hi"}}] = response.choices
    IO.puts("  openai.json: OpenAI.Chat.create_completion/2 called end to end")

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body)["stream"] == true

      chunk = fn text ->
        "data: " <>
          JSON.encode!(%{
            "id" => "c",
            "object" => "chat.completion.chunk",
            "created" => 1,
            "model" => "gpt-5.5",
            "choices" => [%{"index" => 0, "delta" => %{"content" => text}}]
          }) <> "\n\n"
      end

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, chunk.("Hel") <> chunk.("lo") <> "data: [DONE]\n\n")
    end)

    text =
      chat.create_completion_stream!(
        [model: "gpt-5.5", messages: [%{role: "user", content: "Hello"}]],
        api_key: "sk-test",
        req_options: [plug: {Req.Test, __MODULE__}]
      )
      |> Enum.map_join(fn chunk -> hd(chunk.choices).delta.content end)

    assert text == "Hello"
    IO.puts("  openai.json: OpenAI.Chat.create_completion_stream!/2 streamed end to end")
  end

  # A real chat completion decodes into the generated structs.
  defp decode_chat_completion! do
    # Called dynamically: the module only exists once the test generated it.
    response_module = Module.concat(["OpenAI.Schemas.CreateChatCompletionResponse"])

    response =
      response_module.decode(%{
        "id" => "chatcmpl-1",
        "object" => "chat.completion",
        "created" => 1_700_000_000,
        "model" => "gpt-5.5",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "Hello!", "refusal" => nil}
          }
        ],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7},
        "service_tier" => "default",
        "a_field_from_the_future" => true
      })

    assert response.id == "chatcmpl-1"
    assert [%{finish_reason: "stop", message: message}] = response.choices
    assert message.__struct__ == OpenAI.Schemas.ChatCompletionResponseMessage
    assert message.content == "Hello!"
    assert response.usage.__struct__ == OpenAI.Schemas.CompletionUsage
    assert response.usage.total_tokens == 7
    assert response.__extra__ == %{"a_field_from_the_future" => true}
    IO.puts("  openai.json: a chat completion decodes into the generated structs")
  end

  defp count(term, fun) do
    case term do
      %{} = map ->
        self = if fun.(map), do: 1, else: 0

        Enum.reduce(map, self, fn
          {key, _}, acc when key in ~w(example default enum const examples) -> acc
          {"x-" <> _, _}, acc -> acc
          {_, v}, acc -> acc + count(v, fun)
        end)

      list when is_list(list) ->
        Enum.reduce(list, 0, &(&2 + count(&1, fun)))

      _ ->
        0
    end
  end

  defp refs_outside_literals(%{"$ref" => ref} = map) when is_binary(ref),
    do: [ref | refs_outside_literals(Map.delete(map, "$ref"))]

  defp refs_outside_literals(map) when is_map(map) do
    Enum.flat_map(map, fn
      {key, _} when key in ~w(example default enum const) ->
        []

      {"x-" <> _, _} ->
        []

      {"examples", examples} when is_map(examples) ->
        Enum.flat_map(examples, fn {_, e} -> Map.get(e, "$ref") |> List.wrap() end)

      {_, value} ->
        refs_outside_literals(value)
    end)
  end

  defp refs_outside_literals(list) when is_list(list),
    do: Enum.flat_map(list, &refs_outside_literals/1)

  defp refs_outside_literals(_), do: []
end
