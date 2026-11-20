defmodule Infusion.Runtime.DriftTest do
  # Not async: the findings table is shared.
  use ExUnit.Case, async: false
  alias Infusion.Runtime.{Config, Drift, Request}

  # Stand-ins for generated modules, with the rules generated SDKs carry.
  defmodule Label do
    defstruct [:name, :color, __extra__: %{}, __present__: []]
    def __schema__(:fields), do: [{:name, "name", :string}, {:color, "color", :string}]
    def __schema__(:required), do: ["name"]
    def __schema__(:nullable), do: []
  end

  defmodule Issue do
    defstruct [:id, :title, :state, :labels, :body, :reactions, __extra__: %{}, __present__: []]

    def __schema__(:fields) do
      [
        {:id, "id", :integer},
        {:title, "title", :string},
        {:state, "state", {:enum, ["open", "closed"]}},
        {:labels, "labels", {:array, {:ref, Label}}},
        {:body, "body", :string},
        {:reactions, "reactions", {:map, :integer}}
      ]
    end

    def __schema__(:required), do: ["id", "title", "state"]
    def __schema__(:nullable), do: ["body"]
  end

  defmodule Created do
    defstruct [:type, :issue, __extra__: %{}, __present__: []]

    def __schema__(:fields),
      do: [{:type, "type", {:const, "created"}}, {:issue, "issue", {:ref, Issue}}]

    def __schema__(:required), do: ["type"]
    def __schema__(:nullable), do: []
  end

  defmodule Event do
    def __schema__(:type), do: {:union, [{:ref, Created}], {"type", %{"created" => Created}}}
  end

  # GitHub's app permissions: a few names listed, any other name a string.
  defmodule Permissions do
    defstruct [:issues, __extra__: %{}, __present__: []]
    def __schema__(:fields), do: [{:issues, "issues", :string}]
    def __schema__(:required), do: []
    def __schema__(:nullable), do: []
    def __schema__(:additional), do: :string
  end

  # Generated before drift checking: no :required / :nullable clauses.
  defmodule OldLabel do
    defstruct [:name, __extra__: %{}, __present__: []]
    def __schema__(:fields), do: [{:name, "name", :string}]
  end

  @issue %{
    "id" => 1,
    "title" => "Crash",
    "state" => "open",
    "body" => nil,
    "labels" => [%{"name" => "bug", "color" => "f00"}],
    "reactions" => %{"+1" => 2}
  }

  setup do
    Drift.reset()
    on_exit(fn -> Application.delete_env(:infusion_runtime, :drift) end)
  end

  describe "check/2" do
    test "a response that matches the spec has no findings" do
      assert Drift.check(@issue, {:ref, Issue}) == []
      # number accepts integers; null in a nullable field is fine
      assert Drift.check([@issue], {:array, {:ref, Issue}}) == []
    end

    test "every kind of disagreement, located in its schema" do
      json =
        @issue
        |> Map.delete("title")
        |> Map.merge(%{
          "id" => "1",
          "state" => "locked",
          "labels" => [%{"name" => nil, "color" => 3, "default" => true}],
          "reactions" => %{"+1" => "two"},
          "author_association" => "OWNER"
        })

      findings = Drift.check(json, {:ref, Issue})
      at = &"#{String.replace(&1.schema, "Infusion.Runtime.DriftTest.", "")}.#{&1.path}"

      assert Enum.map(findings, &{&1.kind, at.(&1), &1.expected, &1.got}) == [
               {:wrong_type, "Issue.id", "integer", "string"},
               {:missing_required, "Issue.title", nil, nil},
               {:unknown_enum, "Issue.state", nil, "locked"},
               {:unexpected_null, "Label.name", nil, "null"},
               {:wrong_type, "Label.color", "string", "integer"},
               {:undocumented_field, "Label.default", nil, "boolean"},
               {:wrong_type, "Issue.reactions{}", "integer", "string"},
               {:undocumented_field, "Issue.author_association", nil, "string"}
             ]
    end

    test "unions: an unknown discriminator value, and a value no variant fits" do
      assert [%{kind: :unknown_variant, path: "type", got: "deleted"}, %{kind: :unmatched_union}] =
               Drift.check(%{"type" => "deleted"}, {:ref, Event})

      assert [%{kind: :wrong_type, path: "issue.title"} | _] =
               Drift.check(
                 %{"type" => "created", "issue" => Map.put(@issue, "title", 5)},
                 {:ref, Event}
               )
               |> Enum.map(&%{&1 | path: "issue." <> &1.path})
    end

    test "objects where the spec has something else, and the reverse" do
      assert [%{kind: :wrong_type, expected: "object", got: "string"}] =
               Drift.check(Map.put(@issue, "labels", ["bug"]), {:ref, Issue})

      assert [%{kind: :wrong_type, expected: "array", got: "object"}] =
               Drift.check(%{}, {:array, :string})
    end

    test "keys a typed additionalProperties allows are documented, but type-checked" do
      assert Drift.check(%{"issues" => "read", "actions" => "write"}, {:ref, Permissions}) == []

      assert [%{kind: :wrong_type, path: "pages", expected: "string", got: "boolean"}] =
               Drift.check(%{"pages" => true}, {:ref, Permissions})
    end

    test "SDKs generated before drift checking skip the required and null checks" do
      assert [%{kind: :undocumented_field, path: "x"}] =
               Drift.check(%{"x" => 1}, {:ref, OldLabel})

      assert Drift.check(%{"name" => nil}, {:ref, OldLabel}) == []
    end
  end

  describe "recording through real calls" do
    defp config(extra) do
      Config.new([
        [
          base_url: "http://api.test",
          max_retries: 0,
          req_options: [plug: {Req.Test, __MODULE__}]
        ],
        extra
      ])
    end

    @op %{method: :get, path: "/issues/{id}", path_params: ["id"], response: {:ref, Issue}}

    test "off by default: nothing is checked" do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Map.put(@issue, "new", 1)))
      assert {:ok, %Issue{}} = Request.run(config([]), @op, [1], [])
      assert Drift.report() == []
    end

    test "on: findings are counted per operation, and decoding is unchanged" do
      Req.Test.stub(
        __MODULE__,
        &Req.Test.json(&1, Map.merge(@issue, %{"new" => 1, "state" => "x"}))
      )

      ref = :telemetry_test.attach_event_handlers(self(), [[:infusion, :drift]])

      for _ <- 1..3 do
        assert {:ok, %Issue{state: "x", __extra__: %{"new" => 1}}} =
                 Request.run(config(drift: true), @op, [1], [])
      end

      list_op = %{method: :get, path: "/issues", response: {:array, {:ref, Issue}}}
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, [Map.put(@issue, "new", 1)]))
      assert {:ok, [_]} = Request.run(config(drift: true), list_op, [], [])

      assert [
               %{
                 kind: :undocumented_field,
                 path: "new",
                 got: "integer",
                 count: 4,
                 operations: ["GET /issues", "GET /issues/{id}"]
               },
               %{kind: :unknown_enum, path: "state", got: "x", count: 3}
             ] = Drift.report()

      assert_received {[:infusion, :drift], ^ref, %{count: 2},
                       %{operation: "GET /issues/{id}", findings: [_, _]}}
    end

    test "the application setting, a per-call false, and sampling" do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Map.put(@issue, "new", 1)))
      Application.put_env(:infusion_runtime, :drift, true)

      Request.run(config(drift: false), @op, [1], [])
      assert Drift.report() == []

      Request.run(config([]), @op, [1], [])
      assert [%{count: 1}] = Drift.report()

      Application.put_env(:infusion_runtime, :drift, 0.0001)
      :rand.seed(:exsss, {1, 2, 3})
      for _ <- 1..50, do: Request.run(config([]), @op, [1], [])
      assert [%{count: count}] = Drift.report()
      assert count < 5
    end

    test "stream events are checked too" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(
          200,
          ~s(data: {"type":"created","issue":{"id":1,"title":"t","state":"open","pinned":true}}\n\ndata: {"type":"deleted"}\n\n)
        )
      end)

      op = %{method: :post, path: "/events", response: nil, stream_response: {:ref, Event}}
      assert {:ok, stream} = Request.stream(config(drift: true), op, [], [])
      assert [%Created{}, %{"type" => "deleted"}] = Enum.to_list(stream)

      assert [:undocumented_field, :unknown_variant, :unmatched_union] =
               Drift.report() |> Enum.map(& &1.kind) |> Enum.sort()
    end

    test "export writes JSON without response data, format reads well" do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Map.put(@issue, "secret_token", "s3cr3t")))
      Request.run(config(drift: true), @op, [1], [])

      path = Path.join(System.tmp_dir!(), "drift-#{System.unique_integer([:positive])}.json")
      Drift.export(path)
      text = File.read!(path)
      File.rm!(path)

      refute text =~ "s3cr3t"

      assert %{
               "infusion_drift" => 1,
               "findings" => [%{"kind" => "undocumented_field", "path" => "secret_token"}]
             } =
               Jason.decode!(text)

      assert Drift.format() =~
               "undocumented_field  Infusion.Runtime.DriftTest.Issue.secret_token (string)  (1x)"

      Drift.reset()
      assert Drift.format() =~ "No drift seen"
    end
  end
end
