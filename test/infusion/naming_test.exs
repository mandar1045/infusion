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

  test "tag + operation ID, without version prefixes or repeated words (Twilio, OpenAI)" do
    assert %{module: ["RecordingTranscription"], function: "list", strategy: :tag} =
             name(
               %{
                 "tags" => ["Api20100401RecordingTranscription"],
                 "operationId" => "ListRecordingTranscription"
               },
               "/x",
               "get"
             )

    assert %{module: ["Chat"], function: "create_completion"} =
             name(%{"tags" => ["Chat"], "operationId" => "createChatCompletion"}, "/x", "post")

    assert %{module: ["FineTuning"], function: "list_job_checkpoints"} =
             name(
               %{"tags" => ["Fine-tuning"], "operationId" => "listFineTuningJobCheckpoints"},
               "/x",
               "get"
             )
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
