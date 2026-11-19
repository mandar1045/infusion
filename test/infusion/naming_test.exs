defmodule Infusion.NamingTest do
  use ExUnit.Case, async: true
  alias Infusion.Naming

  defp name(op, path, method),
    do: Naming.operation(op, path, method) |> Map.take([:module, :function, :strategy])

  test "vendor SDK hints win (Cloudflare)" do
    op = %{
      "tags" => ["CWS Basic Auth Credentials"],
      "operationId" => "cws-get-basic-auth-secret",
      "x-fern-sdk-group-name" => "zero-trust.cws.basic-auth-credentials.secrets",
      "x-fern-sdk-method-name" => "get"
    }

    assert name(op, "/x", "get") == %{
             module: ["ZeroTrust", "Cws", "BasicAuthCredentials", "Secrets"],
             function: "get",
             strategy: :vendor_hint
           }
  end

  test "group/action operation IDs (GitHub)" do
    assert name(%{"tags" => ["repos"], "operationId" => "repos/get-pages-build"}, "/x", "get") ==
             %{module: ["Repos"], function: "get_pages_build", strategy: :grouped_id}
  end

  describe "path-based names when there is no tag (Stripe)" do
    test "collections and items" do
      assert %{module: ["Customers"], function: "list"} = name(%{}, "/v1/customers", "get")
      assert %{module: ["Customers"], function: "create"} = name(%{}, "/v1/customers", "post")

      assert %{module: ["Customers"], function: "retrieve"} =
               name(%{}, "/v1/customers/{customer}", "get")

      assert %{module: ["Customers"], function: "update"} =
               name(%{}, "/v1/customers/{customer}", "post")

      assert %{module: ["Customers"], function: "delete"} =
               name(%{}, "/v1/customers/{customer}", "delete")
    end

    test "singular resources and reads of sub-resources" do
      assert %{module: ["Organization", "SpendLimit"], function: "delete"} =
               name(%{}, "/organization/spend_limit", "delete")

      assert %{module: ["Organization", "SpendLimit"], function: "retrieve"} =
               name(%{}, "/organization/spend_limit", "get")

      assert %{module: ["Charges", "Dispute"], function: "retrieve"} =
               name(%{}, "/v1/charges/{charge}/dispute", "get")

      assert %{module: ["Charges"], function: "dispute"} =
               name(%{}, "/v1/charges/{charge}/dispute", "post")

      assert %{module: ["Accounts", "People"], function: "list"} =
               name(%{}, "/v1/accounts/{account}/people", "get")

      assert %{module: ["Accounts", "People"], function: "create"} =
               name(%{}, "/v1/accounts/{account}/people", "post")
    end

    test "namespaces, actions and nested resources" do
      assert %{module: ["Terminal", "Configurations"], function: "list"} =
               name(%{}, "/v1/terminal/configurations", "get")

      assert %{module: ["Treasury", "OutboundPayments"], function: "cancel"} =
               name(%{}, "/v1/treasury/outbound_payments/{id}/cancel", "post")

      assert %{module: ["Customers", "Sources"], function: "create"} =
               name(%{}, "/v1/customers/{customer}/sources", "post")
    end
  end

  test "the tag and operation ID, when the path names no resource" do
    assert %{module: ["RecordingTranscription"], function: "list", strategy: :tag} =
             name(
               %{
                 "tags" => ["Api20100401RecordingTranscription"],
                 "operationId" => "ListRecordingTranscription"
               },
               "/{id}",
               "get"
             )

    assert %{module: ["Chat"], function: "create_completion"} =
             name(%{"tags" => ["Chat"], "operationId" => "createChatCompletion"}, "/", "post")
  end

  describe "remote procedure calls: the path ends in the operation ID" do
    test "SOAP operations behind JSON (Lather): POST /api/<Operation>" do
      for {id, function} <- [
            {"GetUser", "get_user"},
            {"ListUsers", "list_users"},
            {"CreateUser", "create_user"}
          ] do
        assert name(%{"tags" => ["operations"], "operationId" => id}, "/api/#{id}", "post") ==
                 %{module: ["Operations"], function: function, strategy: :rpc}
      end
    end

    test "Slack-style method paths; the tag's words leave the function" do
      assert %{module: ["Chat"], function: "post_message", strategy: :rpc} =
               name(
                 %{"tags" => ["chat"], "operationId" => "chat_postMessage"},
                 "/chat.postMessage",
                 "post"
               )

      assert %{module: ["Conversations"], function: "list", strategy: :rpc} =
               name(
                 %{"tags" => ["conversations"], "operationId" => "conversations_list"},
                 "/conversations.list",
                 "get"
               )
    end

    test "one-word operation IDs and other operation IDs keep the path's name" do
      assert %{module: ["Health"], function: "retrieve", strategy: :path} =
               name(%{"tags" => ["Observability"], "operationId" => "health"}, "/health", "get")

      assert %{module: ["Customers"], function: "create", strategy: :path} =
               name(%{"operationId" => "PostCustomers"}, "/v1/customers", "post")
    end
  end

  describe "the official SDK call in the examples (OpenAI's x-oaiMeta)" do
    defp oai(python), do: %{"x-oaiMeta" => %{"examples" => %{"request" => %{"python" => python}}}}

    test "module path and function from the call" do
      assert name(
               oai("client = OpenAI()\nclient.beta.assistants.list(limit=20)"),
               "/assistants",
               "get"
             ) ==
               %{module: ["Beta", "Assistants"], function: "list", strategy: :official_example}
    end

    test "the last call is the one shown; response wrappers are dropped" do
      python =
        "page = client.chat.completions.list()\nclient.chat.completions.retrieve(completion_id)"

      assert %{module: ["Chat", "Completions"], function: "retrieve"} =
               name(oai(python), "/chat/completions/{completion_id}", "get")

      assert %{module: ["Audio", "Speech"], function: "create"} =
               name(
                 oai("with openai.audio.speech.with_streaming_response.create(model=m) as r:"),
                 "/audio/speech",
                 "post"
               )
    end

    test "JavaScript when there's no Python, and a beta flag in the path" do
      op = %{
        "x-oaiMeta" => %{
          "examples" => [%{"request" => %{"javascript" => "await client.responses.cancel(id);"}}]
        }
      }

      assert %{module: ["Beta", "Responses"], function: "cancel"} =
               name(op, "/responses/{id}/cancel?beta=true", "post")
    end

    test "examples without a call fall back to the path" do
      op = %{
        "x-oaiMeta" => %{
          "examples" => %{"request" => %{"curl" => "curl https://api.openai.com/v1/batches"}}
        }
      }

      assert %{module: ["Batches"], function: "list", strategy: :path} =
               name(op, "/batches", "get")
    end
  end

  describe "path rules" do
    test "a POST to a singular path creates, unless the path can also be read" do
      assert %{module: ["Audio", "Speech"], function: "create"} =
               Naming.operation(%{}, "/audio/speech", "post", methods: ["post"])

      assert %{module: ["Organization", "SpendLimit"], function: "update"} =
               Naming.operation(%{}, "/organization/spend_limit", "post",
                 methods: ["get", "post", "delete"]
               )
    end

    test "a verb ending the path is an action" do
      assert %{module: ["FineTuning", "Alpha", "Graders"], function: "validate"} =
               name(%{}, "/fine_tuning/alpha/graders/validate", "post")
    end

    test "a path with items under it is a collection, whatever its name" do
      collections = MapSet.new(["/organization/external_storage"])

      assert %{module: ["Organization", "ExternalStorage"], function: "list"} =
               Naming.operation(%{}, "/organization/external_storage", "get",
                 collections: collections
               )
    end

    test "a named member of a collection is a function on it (Stripe search, Wikimedia streams)" do
      assert %{module: ["Customers"], function: "search"} =
               Naming.operation(%{}, "/v1/customers/search", "get",
                 methods: ["get"],
                 collections: MapSet.new(["/v1/customers"])
               )

      assert %{module: ["Stream"], function: "mediawiki_recentchange"} =
               Naming.operation(%{}, "/v2/stream/mediawiki.recentchange", "get",
                 methods: ["get"],
                 collections: MapSet.new(["/v2/stream"])
               )
    end

    test "a member with several methods is a collection of its own (Twilio)" do
      context = [
        methods: ["get", "post"],
        collections: MapSet.new(["/2010-04-01/Accounts/{AccountSid}/IncomingPhoneNumbers"])
      ]

      path = "/2010-04-01/Accounts/{AccountSid}/IncomingPhoneNumbers/Local.json"

      assert %{module: ["Accounts", "IncomingPhoneNumbers", "Local"], function: "list"} =
               Naming.operation(%{}, path, "get", context)

      assert %{module: ["Accounts", "IncomingPhoneNumbers", "Local"], function: "create"} =
               Naming.operation(%{}, path, "post", context)
    end

    test "a path with a file extension is the collection of its items (Twilio)" do
      # /Calls/{CallSid}/Siprec/{Sid}.json makes /Calls/{CallSid}/Siprec a
      # collection, which /Calls/{CallSid}/Siprec.json is.
      context = [
        methods: ["post"],
        collections:
          MapSet.new([
            "/2010-04-01/Accounts/{AccountSid}/Calls",
            "/2010-04-01/Accounts/{AccountSid}/Calls/{CallSid}/Siprec"
          ])
      ]

      assert %{module: ["Accounts", "Calls", "Siprec"], function: "create"} =
               Naming.operation(
                 %{},
                 "/2010-04-01/Accounts/{AccountSid}/Calls/{CallSid}/Siprec.json",
                 "post",
                 context
               )
    end

    test "file extensions and version segments are not names (Twilio)" do
      assert %{module: ["Accounts", "Calls"], function: "retrieve"} =
               name(%{}, "/2010-04-01/Accounts/{AccountSid}/Calls/{Sid}.json", "get")
    end
  end

  test "word splitting and case conversion" do
    assert Naming.words("createChatCompletion") == ["create", "chat", "completion"]
    assert Naming.words("GetHTTPResponse") == ["get", "http", "response"]
    assert Naming.words("delete-project-api-key") == ["delete", "project", "api", "key"]
    assert Naming.module_part("vector stores") == "VectorStores"
    assert Naming.module_part("3ds") == "M3ds"
    assert Naming.function_name("2fa-enable") == "op_2fa_enable"
  end
end
