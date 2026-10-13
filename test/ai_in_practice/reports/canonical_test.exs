defmodule AiInPractice.Reports.CanonicalTest do
  use ExUnit.Case, async: true

  alias AiInPractice.Reports.Canonical

  test "sorts keys at every depth and writes no whitespace" do
    term = %{"b" => [%{"z" => 1, "a" => true}], "a" => %{"y" => nil, "x" => "s"}}
    assert Canonical.encode!(term) == ~s({"a":{"x":"s","y":null},"b":[{"a":true,"z":1}]})
  end

  test "is stable however the map was built" do
    pairs = for i <- 1..40, do: {"k#{i}", i}
    forward = Map.new(pairs)
    backward = pairs |> Enum.reverse() |> Enum.into(%{})
    assert Canonical.encode!(forward) == Canonical.encode!(backward)
  end

  test "sorts keys by their UTF-8 bytes" do
    assert Canonical.encode!(%{"é" => 1, "z" => 2, "Z" => 3, "a" => 4}) ==
             ~s({"Z":3,"a":4,"z":2,"é":1})
  end

  test "atom keys and values encode as the strings they name" do
    assert Canonical.encode!(%{role: :finance, ok: false}) ==
             Canonical.encode!(%{"role" => "finance", "ok" => false})
  end

  test "re-encoding the decoded bytes gives the same bytes" do
    term = %{
      "quote" => "She said “it’s fine” — \"really\"\n\ttabbed \\ slash </script>",
      "n" => -42,
      "list" => [nil, true, [], %{}],
      "emoji" => "🙂"
    }

    bytes = Canonical.encode!(term)
    assert bytes |> Jason.decode!() |> Canonical.encode!() == bytes
    assert Jason.decode!(bytes) == term
  end

  test "refuses floats, structs, tuples and odd keys" do
    assert_raise ArgumentError, ~r/floats/, fn -> Canonical.encode!(%{"x" => 1.5}) end
    assert_raise ArgumentError, ~r/Date/, fn -> Canonical.encode!(%{"d" => ~D[2026-10-13]}) end
    assert_raise ArgumentError, ~r/tuple/, fn -> Canonical.encode!([{:a, 1}]) end
    assert_raise ArgumentError, ~r/keys/, fn -> Canonical.encode!(%{1 => "x"}) end
    assert_raise ArgumentError, ~r/keys/, fn -> Canonical.encode!(%{nil => "x"}) end
  end

  test "refuses a map whose atom and string keys collide" do
    assert_raise ArgumentError, ~r/duplicate/, fn -> Canonical.encode!(%{:a => 1, "a" => 2}) end
  end
end
