defmodule Infusion.Runtime.ConfigTest do
  use ExUnit.Case, async: true

  alias Infusion.Runtime.Config

  test "layers merge left to right, ignoring unknown keys" do
    config =
      Config.new([
        [base_url: "https://a", max_retries: 2, headers: [{"X-Version", "1"}, {"x-keep", "k"}]],
        %{max_retries: 5},
        [timeout: 10, raw: true, headers: [{"x-version", "2"}]]
      ])

    assert config.base_url == "https://a"
    assert config.max_retries == 5
    assert config.timeout == 10
    assert config.headers == [{"x-keep", "k"}, {"x-version", "2"}]
  end

  test "credentials: literal, env var, function" do
    assert Config.credential(Config.new([[api_key: "k"]])) == "k"
    System.put_env("INFUSION_TEST_KEY", "from-env")
    assert Config.credential(Config.new([[api_key: {:env, "INFUSION_TEST_KEY"}]])) == "from-env"
    assert Config.credential(Config.new([[api_key: fn -> "from-fun" end]])) == "from-fun"
    assert Config.credential(Config.new([[api_key: {:env, "INFUSION_UNSET_VAR"}]])) == nil
  end
end
