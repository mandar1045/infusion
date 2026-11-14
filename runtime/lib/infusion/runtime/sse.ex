defmodule Infusion.Runtime.SSE do
  @moduledoc """
  An incremental parser for Server-Sent Events (`text/event-stream`), as the
  [HTML standard](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation)
  describes them.

  Network chunks don't line up with events, so the parser keeps what it
  hasn't finished:

      iex> alias Infusion.Runtime.SSE
      iex> {[], state} = SSE.parse(SSE.new(), "event: delta\\nda")
      iex> {[event], _state} = SSE.parse(state, "ta: {\\"x\\": 1}\\n\\n")
      iex> {event.event, event.data}
      {"delta", "{\\"x\\": 1}"}

  Lines end with `\\n`, `\\r\\n` or `\\r`, even when a `\\r\\n` is split across
  two chunks. `data` lines of one event are joined with `\\n`. Comments
  (`: keep-alive`) are skipped.
  """

  defmodule Event do
    @moduledoc "One event: `data` is always a string; `event`, `id` and `retry` may be nil."
    defstruct event: nil, data: "", id: nil, retry: nil

    @type t :: %__MODULE__{
            event: String.t() | nil,
            data: String.t(),
            id: String.t() | nil,
            retry: non_neg_integer | nil
          }
  end

  defstruct buffer: "", skip_lf?: false, event: nil, data: [], id: nil, retry: nil

  @type t :: %__MODULE__{}

  @doc "A parser with nothing buffered."
  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc "Feeds one chunk. Returns the events it completed and the new state."
  @spec parse(t, binary) :: {[Event.t()], t}
  def parse(%__MODULE__{} = state, ""), do: {[], state}

  def parse(%__MODULE__{} = state, chunk) do
    chunk =
      if state.skip_lf? and String.starts_with?(chunk, "\n"),
        do: binary_part(chunk, 1, byte_size(chunk) - 1),
        else: chunk

    text = state.buffer <> chunk

    # A trailing \r ends its line, but may be the first half of a \r\n
    # split across chunks: then the next chunk's leading \n is not a line.
    {lines, [rest]} = text |> String.split(~r/\r\n|\r|\n/) |> Enum.split(-1)
    state = %{state | buffer: rest, skip_lf?: String.ends_with?(text, "\r")}

    {events, state} =
      Enum.reduce(lines, {[], state}, fn line, {events, state} ->
        case line(state, line) do
          {:dispatch, event, state} -> {[event | events], state}
          state -> {events, state}
        end
      end)

    {Enum.reverse(events), state}
  end

  @doc """
  Ends the stream: returns an event that was still open (the standard
  discards it; servers that forget the last blank line are common enough to
  be forgiving).
  """
  @spec flush(t) :: [Event.t()]
  def flush(%__MODULE__{} = state) do
    # A last line without a line ending still counts; it can't dispatch.
    state = if state.buffer != "", do: line(state, state.buffer), else: state

    case line(%{state | buffer: ""}, "") do
      {:dispatch, event, _state} -> [event]
      _state -> []
    end
  end

  # A blank line dispatches the event, if it has data.
  defp line(%{data: []} = state, ""), do: %{state | event: nil, retry: nil}

  defp line(state, "") do
    event = %Event{
      event: state.event,
      data: state.data |> Enum.reverse() |> Enum.join("\n"),
      id: state.id,
      retry: state.retry
    }

    {:dispatch, event, %{state | event: nil, data: [], retry: nil}}
  end

  defp line(state, ":" <> _comment), do: state

  defp line(state, line) do
    {field, value} =
      case :binary.split(line, ":") do
        [field, " " <> value] -> {field, value}
        [field, value] -> {field, value}
        [field] -> {field, ""}
      end

    case field do
      "event" -> %{state | event: value}
      "data" -> %{state | data: [value | state.data]}
      "id" -> if String.contains?(value, <<0>>), do: state, else: %{state | id: value}
      "retry" -> retry(state, value)
      _ -> state
    end
  end

  defp retry(state, value) do
    case Integer.parse(value) do
      {ms, ""} when ms >= 0 -> %{state | retry: ms}
      _ -> state
    end
  end
end
