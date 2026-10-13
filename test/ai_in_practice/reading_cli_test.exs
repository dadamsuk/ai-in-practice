defmodule AiInPractice.ReadingCLITest do
  use AiInPractice.DataCase

  import ExUnit.CaptureIO

  alias AiInPractice.ReadingCLI

  @moduletag :tmp_dir

  test "import loads the shipped library, and again updates it" do
    assert {:ok, out} = ReadingCLI.run(["import"])
    assert out == "imported 64 resources: 64 added, 0 updated, 0 made inactive\n"

    assert {:ok, out} = ReadingCLI.run(["import"])
    assert out =~ "0 added, 64 updated"
  end

  test "import from a path, and a bad one changes nothing", %{tmp_dir: dir} do
    path = Path.join(dir, "bad.json")
    File.write!(path, "[]")
    assert {:error, message} = ReadingCLI.run(["import", path])
    assert message =~ ~s(no "resources" list)
    assert message =~ "nothing was changed"
    assert {:ok, "the reading list is empty\n"} = ReadingCLI.run(["list"])
  end

  test "list shows id, state, levels and title" do
    {:ok, _} = ReadingCLI.run(["import"])
    {:ok, out} = ReadingCLI.run(["list"])
    assert out =~ ~r/^\s+\d+  active    Intermediate\s+How I use LLMs$/m
    assert length(String.split(out, "\n", trim: true)) == 64
  end

  test "anything else prints the usage" do
    assert {:error, usage} = ReadingCLI.run(["frobnicate"])
    assert usage =~ "reading import [PATH]"
    assert {:error, _} = ReadingCLI.run(["import", "a", "b"])
  end

  test "rpc decodes base64 arguments and writes the output or the error" do
    assert capture_io(fn -> ReadingCLI.rpc(" " <> Base.encode64("list")) end) =~
             "the reading list is empty"

    assert capture_io(fn -> ReadingCLI.rpc(" " <> Base.encode64("nope")) end) =~ "error: usage"
  end
end
