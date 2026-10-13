defmodule AiInPractice.Snapshot do
  @moduledoc """
  Snapshot assertions for prompts, so any change to a prompt is
  deliberate. Run with `UPDATE_SNAPSHOTS=1` to rewrite the files under
  `test/snapshots`, then review the diff before committing.
  """

  import ExUnit.Assertions

  @dir Path.expand("../snapshots", __DIR__)

  def assert_snapshot(name, actual) do
    path = Path.join(@dir, name)

    if System.get_env("UPDATE_SNAPSHOTS") in ["1", "true"] do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, actual)
    else
      assert File.exists?(path),
             "no snapshot #{name}: run the test with UPDATE_SNAPSHOTS=1 and review it"

      assert actual == File.read!(path),
             "#{name} changed: if this is deliberate, run with UPDATE_SNAPSHOTS=1 and review the diff"
    end
  end
end
