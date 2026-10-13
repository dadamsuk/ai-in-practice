defmodule Mix.Tasks.LinksTest do
  use AiInPractice.DataCase

  alias AiInPractice.Links

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "prints the command's output" do
    Mix.Tasks.Links.run(~w(individual --label IND-5))
    assert_received {:mix_shell, :info, [out]}
    assert out =~ "individual link"
    assert out =~ "IND-5"
    assert [%{label: "IND-5"}] = Links.list_individual_links()
  end

  test "raises with the error message" do
    assert_raise Mix.Error, "no recruiter link with id 7", fn ->
      Mix.Tasks.Links.run(~w(revoke recruiter 7))
    end
  end
end
