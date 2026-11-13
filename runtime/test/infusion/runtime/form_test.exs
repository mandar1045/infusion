defmodule Infusion.Runtime.FormTest do
  use ExUnit.Case, async: true
  doctest Infusion.Runtime.Form

  alias Infusion.Runtime.Form

  test "Stripe style: nested maps and indexed lists" do
    data = %{
      "customer" => "cus_1",
      "items" => [%{"price" => "p_1", "quantity" => 2}, %{"price" => "p_2"}],
      "metadata" => %{"order" => "6735"},
      "expand" => ["customer", "invoice"],
      "description" => nil
    }

    assert Enum.sort(Form.pairs(data)) == [
             {"customer", "cus_1"},
             {"expand[0]", "customer"},
             {"expand[1]", "invoice"},
             {"items[0][price]", "p_1"},
             {"items[0][quantity]", "2"},
             {"items[1][price]", "p_2"},
             {"metadata[order]", "6735"}
           ]
  end

  test "Twilio style: repeated keys" do
    assert Form.pairs([To: "+1555", StatusCallbackEvent: ["initiated", "ringing"]], :repeat) ==
             [
               {"To", "+1555"},
               {"StatusCallbackEvent", "initiated"},
               {"StatusCallbackEvent", "ringing"}
             ]
  end

  test "scalars" do
    assert Form.encode(%{"a" => true, "b" => 1.5, "c" => :auto}) == "a=true&b=1.5&c=auto"
    assert Form.encode(%{"q" => "a b&c"}) == "q=a+b%26c"
  end
end
