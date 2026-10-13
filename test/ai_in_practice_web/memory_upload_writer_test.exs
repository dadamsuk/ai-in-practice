defmodule AiInPracticeWeb.MemoryUploadWriterTest do
  use ExUnit.Case, async: true

  alias AiInPracticeWeb.MemoryUploadWriter, as: Writer

  defp write_all(chunks, max \\ 1_000) do
    {:ok, state} = Writer.init(max_bytes: max)

    Enum.reduce_while(chunks, {:ok, state}, fn chunk, {:ok, state} ->
      case Writer.write_chunk(chunk, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason, state} -> {:halt, {:error, reason, state}}
      end
    end)
  end

  test "hands over the chunks, in order, as one binary" do
    {:ok, state} = write_all(["one ", "two ", "three"])
    {:ok, state} = Writer.close(state, :done)
    assert Writer.meta(state) == %{audio: "one two three"}
  end

  test "an empty upload is an empty binary" do
    {:ok, state} = write_all([])
    assert Writer.meta(state) == %{audio: ""}
  end

  test "refuses to hold more than max_bytes, and drops what it had" do
    assert {:error, :too_large, state} = write_all(["12345", "67890", "x"], 10)
    assert Writer.meta(state) == %{audio: ""}
  end

  test "exactly max_bytes is accepted" do
    assert {:ok, state} = write_all(["12345", "67890"], 10)
    assert Writer.meta(state).audio == "1234567890"
  end

  test "a cancelled or failed upload drops the audio" do
    for reason <- [:cancel, {:error, :too_large}] do
      {:ok, state} = write_all(["secret audio"])
      {:ok, state} = Writer.close(state, reason)
      assert Writer.meta(state) == %{audio: ""}
    end
  end
end
