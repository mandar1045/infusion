defmodule Infusion.Runtime.Any do
  @moduledoc """
  Stands in for a schema the spec refers to but doesn't define: the JSON is
  kept as it is.
  """

  @type t :: term

  @doc false
  def __schema__(:type), do: :any

  @doc "Returns `json` unchanged."
  def decode(json), do: json
end
