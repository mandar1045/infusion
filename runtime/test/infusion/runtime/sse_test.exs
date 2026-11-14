defmodule Infusion.Runtime.SSETest do
  use ExUnit.Case, async: true
  doctest Infusion.Runtime.SSE

  alias Infusion.Runtime.SSE
  alias Infusion.Runtime.SSE.Event

  defp parse_all(chunks) do
    {events, state} =
      Enum.reduce(chunks, {[], SSE.new()}, fn chunk, {events, state} ->
        {new, state} = SSE.parse(state, chunk)
        {events ++ new, state}
      end)

    events ++ SSE.flush(state)
  end

  @stream """
  : keep-alive comment
  event: response.created
  id: 1
  data: {"type":"response.created"}

  data: line one
  data: line two
  data:no space

  retry: 1500
  data: last

  data: [DONE]

  """

  @expected [
    %Event{event: "response.created", id: "1", data: ~s({"type":"response.created"})},
    %Event{id: "1", data: "line one\nline two\nno space"},
    %Event{id: "1", data: "last", retry: 1500},
    %Event{id: "1", data: "[DONE]"}
  ]

  test "a whole stream" do
    assert parse_all([@stream]) == @expected
  end

  test "the same events however the stream is split into chunks" do
    for at <- 0..byte_size(@stream) do
      <<a::binary-size(^at), b::binary>> = @stream
      assert parse_all([a, b]) == @expected, "split at #{at}"
    end

    assert parse_all(String.graphemes(@stream)) == @expected
  end

  test "CRLF and CR line endings, also when CRLF is split across chunks" do
    crlf = String.replace(@stream, "\n", "\r\n")
    cr = String.replace(@stream, "\n", "\r")

    assert parse_all([crlf]) == @expected
    assert parse_all([cr]) == @expected
    assert parse_all(String.graphemes(cr)) == @expected

    for at <- 0..byte_size(crlf) do
      <<a::binary-size(^at), b::binary>> = crlf
      assert parse_all([a, b]) == @expected, "CRLF split at #{at}"
    end
  end

  test "blank lines without data dispatch nothing; event names don't leak" do
    assert parse_all(["event: ping\n\n\n\ndata: x\n\n"]) == [%Event{data: "x"}]
  end

  test "an unfinished last event is kept on flush" do
    assert parse_all(["data: a\n\ndata: b"]) == [%Event{data: "a"}, %Event{data: "b"}]
    assert parse_all(["data: a\n\ndata: b\n"]) == [%Event{data: "a"}, %Event{data: "b"}]
  end

  test "unknown fields and invalid retry values are ignored" do
    assert parse_all(["foo: bar\nretry: soon\ndata\n\n"]) == [%Event{data: ""}]
  end
end
