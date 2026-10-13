defmodule Mix.Tasks.Assessment.TryTest do
  # Shared sandbox: the session reads the reading list from its own process.
  use AiInPractice.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias AiInPractice.Reading
  alias Mix.Tasks.Assessment.Try

  test "raises with the error message" do
    assert_raise Mix.Error, ~r/unknown role group "pilot"/, fn ->
      Try.run(~w(pilot))
    end
  end

  test "runs a conversation, picking from the active reading list" do
    {:ok, item} =
      Reading.create_item(%{
        title: "A guide",
        url: "https://example.com/g",
        areas: [:attitude]
      })

    out =
      capture_io("An answer.\n", fn ->
        capture_log(fn ->
          assert :ok = Try.run(~w(finance --fake --questions 1))
        end)
      end)

    assert out =~ "SUMMARY"
    assert out =~ "READING PICKS\n- #{item.id}: It picks up where your answers left off."
  end
end
