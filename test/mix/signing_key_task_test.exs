defmodule Mix.Tasks.SigningKeyTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.SigningKey

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "prints the command's output" do
    SigningKey.run(["new"])
    assert_received {:mix_shell, :info, [out]}
    assert out =~ "REPORT_SIGNING_KEY="
  end

  test "raises with the error message" do
    assert_raise Mix.Error, ~r/usage:/, fn -> SigningKey.run(["nope"]) end
  end
end
