defmodule AiInPractice.Eval.StoreTest do
  use ExUnit.Case, async: true

  alias AiInPractice.Eval.Store

  describe "prepare/2" do
    @tag :tmp_dir
    test "makes the directory and its runs folder", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "out")
      assert {:ok, ^dir} = Store.prepare(dir, "/somewhere/else")
      assert File.dir?(Path.join(dir, "runs"))
    end

    test "refuses the repository and anything inside it" do
      repo = File.cwd!()

      for dir <- [repo, Path.join(repo, "tmp/eval"), "eval/out"] do
        assert {:error, message} = Store.prepare(dir, repo)
        assert message =~ "inside the repository"
      end

      refute File.exists?(Path.join(repo, "eval/out"))
    end

    test "a sibling directory that only shares the prefix is allowed" do
      refute Store.inside?("/home/x/repo-eval", "/home/x/repo")
      assert Store.inside?("/home/x/repo/a", "/home/x/repo")
    end

    @tag :tmp_dir
    test "the default is a timestamped directory under ~/ai-in-practice-eval", %{tmp_dir: tmp} do
      assert {:ok, dir} = Store.prepare(nil, "/somewhere/else", tmp)
      assert Path.dirname(dir) == Path.join(tmp, "ai-in-practice-eval")
      assert Path.basename(dir) =~ ~r/^\d{8}T\d{6}Z$/
      assert File.dir?(dir)
    end

    @tag :tmp_dir
    test "an uncreatable directory is an error", %{tmp_dir: tmp} do
      file = Path.join(tmp, "file")
      File.write!(file, "")
      assert {:error, "cannot create " <> _} = Store.prepare(Path.join(file, "out"), "/else")
    end
  end

  describe "encode/1" do
    test "tuples become lists, floats are rounded, structs become maps, odd keys are inspected" do
      json = Store.encode(%{a: {1, :x}, f: 1 / 3, s: URI.parse("http://x"), k: %{{"p", 1} => 2}})
      decoded = Jason.decode!(json)
      assert decoded["a"] == [1, "x"]
      assert decoded["f"] == 0.333333
      assert decoded["s"]["host"] == "x"
      assert decoded["k"] == %{~s({"p", 1}) => 2}
    end
  end

  @tag :tmp_dir
  test "write_run/2 names the file after the persona and run", %{tmp_dir: tmp} do
    {:ok, dir} = Store.prepare(tmp, "/else")
    path = Store.write_run(dir, %{persona: "cfo", run: 2, outcome: :report})
    assert path == Path.join([dir, "runs", "cfo-2.json"])
    assert %{"outcome" => "report"} = path |> File.read!() |> Jason.decode!()
  end
end
