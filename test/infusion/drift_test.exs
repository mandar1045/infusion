defmodule Infusion.DriftTest do
  use ExUnit.Case, async: true
  alias Infusion.{Drift, Patch}

  @spec_path "test/fixtures/drift.json"

  defp finding(kind, schema, path, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => kind,
        "schema" => "Tracker.Schemas." <> schema,
        "path" => path,
        "expected" => nil,
        "got" => nil,
        "count" => 3,
        "operations" => ["GET /issues/{id}"]
      },
      extra
    )
  end

  defp findings do
    [
      finding("undocumented_field", "Issue", "locked", %{"got" => "boolean"}),
      finding("undocumented_field", "Issue", "closed_by", %{"got" => "object"}),
      finding("undocumented_field", "Issue", "closed_by", %{"got" => "null", "count" => 1}),
      finding("unexpected_null", "Issue", "assignee", %{"got" => "null"}),
      finding("missing_required", "Issue", "created_at"),
      finding("unknown_enum", "Issue", "state", %{"got" => "locked"}),
      finding("wrong_type", "Issue", "priority", %{"expected" => "integer", "got" => "string"}),
      finding("unexpected_null", "Issue.Milestone", "due_on", %{"got" => "null"}),
      finding("undocumented_field", "IssuesListResponse", "next", %{
        "got" => "string",
        "operations" => ["GET /issues"]
      }),
      finding("missing_required", "IssuesListResponse", "total", %{
        "operations" => ["GET /issues"]
      }),
      finding("unknown_variant", "Issue", "kind", %{"got" => "epic"})
    ]
  end

  defp build(opts \\ []) do
    {:ok, built} = Infusion.build(@spec_path, Keyword.merge([name: "Tracker"], opts))
    built
  end

  test "every finding is traced to where the spec defines it" do
    entries = Drift.analyze(findings(), build())
    by = Map.new(entries, &{{&1.finding["kind"], &1.finding["path"]}, &1})

    # allOf: the property lives in the second member, not in Issue itself
    assert by[{"unexpected_null", "assignee"}].pointer ==
             "/components/schemas/Issue/allOf/1/properties/assignee"

    # required in the shared base schema, found through the $ref
    assert [
             %{
               "op" => "unrequire",
               "path" => "/components/schemas/Record",
               "value" => ["created_at"]
             }
           ] =
             by[{"missing_required", "created_at"}].patches

    # an enum behind a $ref is fixed where it is defined
    assert [%{"op" => "add_enum", "path" => "/components/schemas/State", "value" => ["locked"]}] =
             by[{"unknown_enum", "state"}].patches

    # an inline object, lifted into its own module
    assert by[{"unexpected_null", "due_on"}].pointer ==
             "/components/schemas/Issue/allOf/1/properties/milestone/properties/due_on"

    # an inline response, lifted into IssuesListResponse
    assert by[{"undocumented_field", "next"}].pointer ==
             "/paths/~1issues/get/responses/200/content/application~1json/schema/properties/next"

    # one undocumented field seen as an object and as null: one property
    assert [%{"value" => %{"type" => "object", "nullable" => true}, "reason" => reason}] =
             by[{"undocumented_field", "closed_by"}].patches

    assert reason == "undocumented_field, seen 4x in GET /issues/{id}"

    # reported, not patched
    assert by[{"unknown_variant", "kind"}].patches == []
  end

  test "patched and regenerated, the SDK has what the API returns" do
    patches = findings() |> Drift.analyze(build()) |> Enum.flat_map(& &1.patches)

    {:ok, %{files: files, warnings: warnings}} =
      Infusion.generate(@spec_path, name: "Tracker", patches: patches)

    assert Enum.filter(warnings, &(is_binary(&1) and &1 =~ "patch")) == []
    issue = Enum.find(files, &(&1.path == "lib/tracker/schemas/issue.ex")).source

    # the new fields, documented as coming from real responses
    assert issue =~ "locked: boolean() | nil"
    assert issue =~ ~s({:closed_by, "closed_by", :any})
    assert issue =~ "Not in the vendor's spec"
    # nullable now, and no longer required
    assert issue =~ "assignee: Tracker.Schemas.User.t() | nil"
    assert issue =~ ~S|def __schema__(:nullable), do: ["assignee", "closed_by"]|
    assert issue =~ ~S|def __schema__(:required), do: ["assignee", "id", "state", "title"]|
    # both types
    assert issue =~ "priority: integer() | String.t() | nil"

    state = Enum.find(files, &(&1.path == "lib/tracker/schemas/state.ex")).source
    assert state =~ ~s({:enum, ["open", "closed", "locked"]})

    list = Enum.find(files, &(&1.path == "lib/tracker/schemas/issues_list_response.ex")).source
    assert list =~ ~S|def __schema__(:required), do: ["items"]|
    assert list =~ ~s({:next, "next", :string})
  end

  test "a patch the spec no longer needs says so" do
    spec = Jason.decode!(File.read!(@spec_path))

    {_doc, warnings} =
      Patch.apply(spec, [
        %{"op" => "add_enum", "path" => "/components/schemas/State", "value" => ["open"]},
        %{"op" => "merge", "path" => "/components/schemas/Gone/properties/x", "value" => %{}},
        %{"op" => "unrequire", "path" => "/components/schemas/User", "value" => ["avatar"]}
      ])

    assert [
             "infusion.exs: patch add_enum /components/schemas/State: the spec already says this (fixed upstream?): remove it",
             "infusion.exs: patch merge /components/schemas/Gone/properties/x: the spec has nothing there any more: remove it",
             "infusion.exs: patch unrequire /components/schemas/User: the spec already says this (fixed upstream?): remove it"
           ] = warnings
  end

  test "JSON Patch operations, escaped pointers, and bad patches" do
    doc = %{"a" => %{"b/c" => [1, 2]}}

    {doc, []} =
      Patch.apply(doc, [
        %{"op" => "add", "path" => "/a/b~1c/-", "value" => 3},
        %{"op" => "replace", "path" => "/a/b~1c/0", "value" => 0},
        %{"op" => "add", "path" => "/a/n", "value" => true},
        %{"op" => "remove", "path" => "/a/n"}
      ])

    assert doc == %{"a" => %{"b/c" => [0, 2, 3]}}
    assert Patch.pointer(["paths", "/a/{b}", "get"]) == "/paths/~1a~1{b}/get"

    assert {:error, "patches: patch 1: op must be" <> _} =
             Patch.load([%{"op" => "move", "path" => "/a"}])

    assert {:error, "patches: patch 1: merge needs an object value"} =
             Patch.load([%{op: :merge, path: "/a", value: 1}])
  end

  test "patches merge into an existing patches file" do
    existing = [%{"op" => "add_enum", "path" => "/s", "value" => ["a"]}]

    assert [%{"value" => ["a", "b"]}, %{"op" => "merge"}] =
             Drift.merge_patches(existing, [
               %{"op" => "add_enum", "path" => "/s", "value" => ["b", "a"]},
               %{"op" => "merge", "path" => "/t", "value" => %{}}
             ])
  end

  test "an issue for the API's owners" do
    text = findings() |> Drift.analyze(build()) |> Drift.issue("Tracker")
    assert text =~ "## The Tracker OpenAPI spec disagrees with the API's responses"

    assert text =~
             "| `/components/schemas/Issue/allOf/1/properties/assignee` | not nullable | `null` | 3 | `GET /issues/{id}` |"
  end

  test "the mix task writes infusion.patches.json, used by the next generation" do
    dir = Path.join(System.tmp_dir!(), "infusion-drift-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(
      Path.join(dir, "infusion.exs"),
      inspect(name: "Tracker", spec: Path.expand(@spec_path))
    )

    File.write!(
      Path.join(dir, "drift.json"),
      Jason.encode!(%{"infusion_drift" => 1, "findings" => findings()})
    )

    issue = Path.join(dir, "issue.md")

    args = [
      Path.join(dir, "drift.json"),
      "--config",
      Path.join(dir, "infusion.exs"),
      "--write",
      "--issue",
      issue
    ]

    Mix.shell(Mix.Shell.Process)
    Mix.Tasks.Infusion.Drift.run(args)
    assert_received {:mix_shell, :info, ["10 disagreements between the spec and the API:\n"]}
    assert File.read!(issue) =~ "Tracker OpenAPI spec"

    patches = Jason.decode!(File.read!(Path.join(dir, "infusion.patches.json")))
    assert length(patches) == 9

    # infusion.exs picks the file up by itself
    {:ok, config} = Infusion.Config.load(Path.join(dir, "infusion.exs"))
    assert config[:patches] == Path.join(dir, "infusion.patches.json")

    # fed the same report again: everything is already fixed
    Mix.Tasks.Infusion.Drift.run(args)
    assert_received {:mix_shell, :info, ["1 disagreement between the spec and the API:\n"]}
    assert_received {:mix_shell, :info, ["9 more already fixed by infusion.patches.json."]}
  after
    Mix.shell(Mix.Shell.IO)
  end
end
