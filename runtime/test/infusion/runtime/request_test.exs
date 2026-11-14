defmodule Infusion.Runtime.RequestTest do
  use ExUnit.Case, async: true

  alias Infusion.Runtime.{Config, Error, Request}

  defmodule Model do
    defstruct [:id, :owned_by, __extra__: %{}, __present__: []]
    def __schema__(:fields), do: [{:id, "id", :string}, {:owned_by, "owned_by", :string}]
  end

  defmodule Message do
    defstruct [:role, :content, __extra__: %{}, __present__: []]
    def __schema__(:fields), do: [{:role, "role", :string}, {:content, "content", :string}]
  end

  setup :verify_on_exit

  def handle_event(event, _measurements, meta, test), do: send(test, {:event, event, meta})

  defp verify_on_exit(_), do: Req.Test.verify_on_exit!()

  # Retries sleep through this, so tests record the waits instead of waiting.
  defp config(extra \\ []) do
    test = self()

    Config.new([
      [
        base_url: "https://api.test/v1",
        api_key: "sk-test",
        req_options: [plug: {Req.Test, __MODULE__}],
        sleep: fn ms -> send(test, {:slept, ms}) end
      ],
      extra
    ])
  end

  @get_model %{
    id: "retrieveModel",
    method: :get,
    path: "/models/{model}",
    path_params: ["model"],
    params: [{:include, "include", :query}, {:org, "OpenAI-Organization", :header}],
    body: nil,
    response: {:ref, Model}
  }

  @create %{
    id: "createChat",
    method: :post,
    path: "/chat/completions",
    path_params: [],
    params: [{:model, "model", :body}, {:messages, "messages", :body}],
    body: :json,
    response: nil
  }

  describe "building requests" do
    test "path params are encoded, query lists repeat, auth and header params are sent" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/models/ft%3Agpt%2F4%20x"
        assert conn.query_string == "include=a&include=b&verbose=true"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-test"]
        assert Plug.Conn.get_req_header(conn, "openai-organization") == ["org-1"]
        Req.Test.json(conn, %{"id" => "ft:gpt/4 x", "owned_by" => "me", "created" => 1})
      end)

      assert {:ok, %Model{id: "ft:gpt/4 x", owned_by: "me", __extra__: %{"created" => 1}}} =
               Request.run(config(), @get_model, ["ft:gpt/4 x"],
                 include: ["a", "b"],
                 org: "org-1",
                 verbose: true
               )
    end

    test "JSON bodies: known and unknown params, structs and atoms encoded" do
      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]

        assert JSON.decode!(body) == %{
                 "model" => "gpt-5.5",
                 "messages" => [%{"role" => "user", "content" => "hi"}],
                 "reasoning" => %{"effort" => "low"}
               }

        Req.Test.json(conn, %{"ok" => true})
      end)

      params = %{
        model: "gpt-5.5",
        messages: [%Message{role: :user, content: "hi"}],
        reasoning: [effort: :low],
        stop: nil
      }

      assert {:ok, %{"ok" => true}} = Request.run(config(), @create, [], params)
    end

    test "form bodies are nested the Stripe way" do
      op = %{@create | body: :form, params: []}

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Plug.Conn.get_req_header(conn, "content-type") == [
                 "application/x-www-form-urlencoded"
               ]

        assert URI.decode_www_form(body) == "items[0][price]=p_1&metadata[order]=6735"
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{}} =
               Request.run(config(), op, [],
                 items: [%{price: "p_1"}],
                 metadata: %{order: 6735}
               )
    end

    test "multipart bodies carry files and fields" do
      op = %{@create | body: :multipart, params: []}

      Req.Test.expect(__MODULE__, fn conn ->
        conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart]))
        assert conn.body_params["purpose"] == "fine-tune"
        assert %Plug.Upload{filename: "data.jsonl"} = conn.body_params["file"]
        Req.Test.json(conn, %{"id" => "file-1"})
      end)

      assert {:ok, %{"id" => "file-1"}} =
               Request.run(config(), op, [],
                 file: {"{}\n", filename: "data.jsonl"},
                 purpose: "fine-tune"
               )
    end

    test "basic, header and query auth" do
      for {auth, key, check} <- [
            {:basic, {"AC1", "tok"}, &(&1.req_headers |> List.keyfind("authorization", 0))},
            {{:header, "x-api-key"}, "k1", &(&1.req_headers |> List.keyfind("x-api-key", 0))},
            {{:query, "key"}, "k2", & &1.query_string}
          ] do
        Req.Test.expect(__MODULE__, fn conn ->
          send(self(), {:auth, check.(conn)})
          Req.Test.json(conn, %{})
        end)

        Request.run(config(auth: auth, api_key: key), @get_model, ["m"], [])
        assert_received {:auth, got}

        assert got in [
                 {"authorization", "Basic " <> Base.encode64("AC1:tok")},
                 {"x-api-key", "k1"},
                 "key=k2"
               ]
      end
    end

    test "no credential, no auth header" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        Req.Test.json(conn, %{})
      end)

      Request.run(config(api_key: {:env, "INFUSION_UNSET_VAR"}), @get_model, ["m"], [])
    end
  end

  describe "retries" do
    test "5xx is retried with exponential backoff, then succeeds" do
      Req.Test.expect(__MODULE__, 2, &Plug.Conn.send_resp(&1, 503, "busy"))
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"id" => "m"}))

      assert {:ok, %Model{id: "m"}} = Request.run(config(), @get_model, ["m"], [])
      assert_received {:slept, first}
      assert_received {:slept, second}
      assert first in 375..500
      assert second in 750..1000
    end

    test "gives up after max_retries with a typed error" do
      Req.Test.expect(__MODULE__, 3, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-request-id", "req_123")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"message" => "Slow down", "type" => "rate_limit"}})
      end)

      assert {:error, %Error{type: :rate_limit, status: 429, request_id: "req_123"} = error} =
               Request.run(config(), @get_model, ["m"], [])

      assert error.message == "429: Slow down"
      assert error.body["error"]["type"] == "rate_limit"
    end

    test "max_retries per call" do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 500, ""))

      assert {:error, %Error{type: :internal_server}} =
               Request.run(config(), @get_model, ["m"], [], max_retries: 0)

      refute_received {:slept, _}
    end

    test "4xx errors are not retried" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, %Error{type: :not_found, message: "404: Not Found"}} =
               Request.run(config(), @get_model, ["m"], [])
    end

    test "x-should-retry overrides the status" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-should-retry", "false")
        |> Plug.Conn.send_resp(500, "")
      end)

      assert {:error, %Error{status: 500}} = Request.run(config(), @get_model, ["m"], [])

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-should-retry", "true")
        |> Plug.Conn.send_resp(400, "")
      end)

      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"id" => "m"}))
      assert {:ok, %Model{}} = Request.run(config(), @get_model, ["m"], [])
    end

    test "the server's retry-after-ms and retry-after are honoured" do
      for {header, value, expected} <- [
            {"retry-after-ms", "1250", 1250},
            {"retry-after", "3", 3000},
            {"retry-after", "1.5", 1500}
          ] do
        Req.Test.expect(__MODULE__, fn conn ->
          conn |> Plug.Conn.put_resp_header(header, value) |> Plug.Conn.send_resp(429, "")
        end)

        Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"id" => "m"}))
        assert {:ok, _} = Request.run(config(), @get_model, ["m"], [])
        assert_received {:slept, ^expected}
      end
    end

    test "retry-after as an HTTP date" do
      at =
        DateTime.utc_now() |> DateTime.add(10) |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      Req.Test.expect(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", at) |> Plug.Conn.send_resp(503, "")
      end)

      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"id" => "m"}))
      assert {:ok, _} = Request.run(config(), @get_model, ["m"], [])
      assert_received {:slept, ms}
      assert ms in 8_000..10_000
    end

    test "a retry-after over a minute falls back to backoff" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "3600") |> Plug.Conn.send_resp(429, "")
      end)

      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"id" => "m"}))
      assert {:ok, _} = Request.run(config(), @get_model, ["m"], [])
      assert_received {:slept, ms}
      assert ms in 375..500
    end

    test "the idempotency key stays the same across retries; retries are counted" do
      test = self()

      Req.Test.expect(__MODULE__, 3, fn conn ->
        [key] = Plug.Conn.get_req_header(conn, "idempotency-key")
        [count] = Plug.Conn.get_req_header(conn, "x-retry-count")
        send(test, {:attempt, key, count})
        Plug.Conn.send_resp(conn, 500, "")
      end)

      config = config(idempotency_header: "idempotency-key", retry_count_header: "x-retry-count")
      Request.run(config, @create, [], model: "m")

      assert_received {:attempt, key, "0"}
      assert_received {:attempt, ^key, "1"}
      assert_received {:attempt, ^key, "2"}
      assert "infusion-" <> _ = key
    end

    test "connection errors and timeouts are retried, then reported" do
      Req.Test.expect(__MODULE__, 3, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{type: :connection, reason: :econnrefused, status: nil}} =
               Request.run(config(), @get_model, ["m"], [])

      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"id" => "m"}))
      assert {:ok, _} = Request.run(config(), @get_model, ["m"], [])

      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))

      assert {:error, %Error{type: :timeout}} =
               Request.run(config(), @get_model, ["m"], [], max_retries: 0)
    end
  end

  describe "results" do
    test "raw: true returns the response with the decoded body" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "9")
        |> Req.Test.json(%{"id" => "m"})
      end)

      assert {:ok, %Req.Response{status: 200, body: %Model{id: "m"}} = response} =
               Request.run(config(), @get_model, ["m"], [], raw: true)

      assert Req.Response.get_header(response, "x-ratelimit-remaining") == ["9"]
    end

    test "non-JSON bodies are returned as they are; empty bodies as nil" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, <<1, 2, 3>>)
      end)

      assert {:ok, <<1, 2, 3>>} = Request.run(config(), @get_model, ["m"], [])

      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 204, ""))
      assert {:ok, nil} = Request.run(config(), @get_model, ["m"], [])
    end

    test "unwrap! returns the value or raises the error" do
      assert Request.unwrap!({:ok, 1}) == 1

      assert_raise Error, "HTTP 500", fn ->
        Request.unwrap!({:error, Error.from_response(500, "", %{}, nil)})
      end
    end

    test "telemetry events" do
      test = self()
      ref = make_ref()

      :telemetry.attach_many(
        inspect(ref),
        [[:infusion, :request, :start], [:infusion, :request, :stop]],
        &__MODULE__.handle_event/4,
        test
      )

      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 502, ""))
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"id" => "m"}))
      Request.run(config(), @get_model, ["m"], [])
      :telemetry.detach(inspect(ref))

      assert_received {:event, [:infusion, :request, :start], %{operation: "retrieveModel"}}
      assert_received {:event, [:infusion, :request, :stop], %{status: 200, retries: 1}}
    end
  end

  describe "streams" do
    defmodule Chunk do
      defstruct [:id, :delta, __extra__: %{}, __present__: []]
      def __schema__(:fields), do: [{:id, "id", :string}, {:delta, "delta", :string}]
    end

    @chat_stream %{
      id: "createChat",
      method: :post,
      path: "/chat/completions",
      path_params: [],
      params: [{:model, "model", :body}, {:stream, "stream", :body}],
      body: :json,
      response: nil,
      stream_response: {:ref, Chunk},
      stream_param: {"stream", true}
    }

    defp sse(conn, status \\ 200, chunks) do
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(status)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end

    test "asks for a stream and decodes each event; [DONE] ends it" do
      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert JSON.decode!(body) == %{"model" => "m", "stream" => true}

        sse(conn, [
          ~s(data: {"id":"c1","delta":"Hel"}\n\nda),
          ~s(ta: {"id":"c1","delta":"lo"}\n\n: ping\n\n),
          "data: [DONE]\n\ndata: {\"id\":\"after-done\"}\n\n"
        ])
      end)

      assert {:ok, stream} = Request.stream(config(), @chat_stream, [], model: "m", stream: false)
      assert [%Chunk{delta: "Hel"}, %Chunk{delta: "lo"}] = Enum.to_list(stream)
    end

    test "stopping early is fine" do
      Req.Test.expect(__MODULE__, fn conn ->
        sse(conn, [~s(data: {"delta":"a"}\n\n), ~s(data: {"delta":"b"}\n\n)])
      end)

      {:ok, stream} = Request.stream(config(), @chat_stream, [], %{model: "m"})
      assert [%Chunk{delta: "a"}] = Enum.take(stream, 1)
    end

    test "errors before the stream starts are retried, then typed" do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, ""))
      Req.Test.expect(__MODULE__, &sse(&1, [~s(data: {"delta":"ok"}\n\n)]))

      assert {:ok, stream} = Request.stream(config(), @chat_stream, [], model: "m")
      assert [%Chunk{delta: "ok"}] = Enum.to_list(stream)
      assert_received {:slept, _}

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-request-id", "req_9")
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"message" => "Unknown model"}})
      end)

      assert {:error,
              %Error{type: :bad_request, request_id: "req_9", message: "400: Unknown model"}} =
               Request.stream(config(), @chat_stream, [], model: "nope")
    end

    test "an error event inside the stream is raised" do
      Req.Test.expect(__MODULE__, fn conn ->
        sse(conn, [
          ~s(data: {"delta":"a"}\n\n),
          ~s(data: {"error":{"message":"Overloaded","type":"server_error"}}\n\n)
        ])
      end)

      {:ok, stream} = Request.stream(config(), @chat_stream, [], model: "m")

      error = assert_raise Error, "Overloaded", fn -> Enum.to_list(stream) end
      assert error.type == :api_error
      assert error.body["error"]["type"] == "server_error"

      Req.Test.expect(__MODULE__, &sse(&1, [~s(event: error\ndata: {"message":"Gone"}\n\n)]))
      {:ok, stream} = Request.stream(config(), @chat_stream, [], model: "m")
      assert_raise Error, "Gone", fn -> Enum.to_list(stream) end
    end

    test "a query stream parameter, on a path that already has a query" do
      op = %{
        @chat_stream
        | method: :get,
          path: "/responses/{id}?beta=true",
          path_params: ["id"],
          params: [{:stream, "stream", :query}],
          body: nil
      }

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.query_string == "beta=true&stream=true"
        sse(conn, [~s(data: {"id":"r1"}\n\n)])
      end)

      assert {:ok, stream} = Request.stream(config(), op, ["r1"], [])
      assert [%Chunk{id: "r1"}] = Enum.to_list(stream)
    end

    test "a plain JSON answer to a stream request is one element" do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"id" => "whole"}))
      op = %{@chat_stream | response: {:ref, Chunk}}
      assert {:ok, [%Chunk{id: "whole"}]} = Request.stream(config(), op, [], model: "m")
    end

    test "text events stay text" do
      Req.Test.expect(__MODULE__, &sse(&1, ["data: plain words\n\n"]))
      {:ok, stream} = Request.stream(config(), @chat_stream, [], model: "m")
      assert Enum.to_list(stream) == ["plain words"]
    end
  end
end
