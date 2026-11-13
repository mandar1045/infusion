defmodule Infusion.Gen.Source do
  @moduledoc false
  # Helpers for writing Elixir source.

  @doc """
  Every Elixir literal written into generated code goes through here:
  `inspect/1` shortens long lists to `[..., ...]` (Stripe has enums with
  hundreds of values) and long strings, which would corrupt the code.
  """
  def lit(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  @doc "A `@doc`/`@moduledoc` value: a heredoc, or `false` when there's nothing to say."
  def doc(text) do
    case text |> to_string() |> String.replace("\r\n", "\n") |> String.trim() do
      "" ->
        "false"

      text ->
        escaped =
          text
          |> String.replace("\\", "\\\\")
          |> String.replace("\#{", "\\\#{")
          |> String.replace(~s("""), ~s(\\"""))

        ~s("""\n) <> escaped <> ~s(\n""")
    end
  end

  @doc "Formats generated source as `mix format` would."
  def format(source),
    do: source |> Code.format_string!() |> IO.iodata_to_binary() |> Kernel.<>("\n")
end
