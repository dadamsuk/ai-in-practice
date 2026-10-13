defmodule AiInPractice.BrowserCheckScriptTest do
  # script/browser-check is a thin wrapper round agent-browser. A fake
  # agent-browser on PATH records the arguments it receives.
  use ExUnit.Case, async: true

  @script Path.expand("../../script/browser-check", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "browser-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    fake = Path.join(dir, "agent-browser")
    File.write!(fake, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    File.chmod!(fake, 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: dir <> ":" <> System.get_env("PATH")}
  end

  defp run(args, env) do
    System.cmd(@script, args, env: env, stderr_to_stdout: true)
  end

  test "passes commands through with the fixed session", %{path: path} do
    {out, 0} = run(["open", "http://100.88.155.65:4100/"], [{"PATH", path}])

    assert out ==
             "--cdp\nws://bigwhite:9000/cdp?session=ai-in-practice&who=claude@dedev\nopen\nhttp://100.88.155.65:4100/\n"
  end

  test "host and session can be overridden", %{path: path} do
    env = [{"PATH", path}, {"BROWSERHOST", "otherhost"}, {"BROWSER_SESSION", "s2"}]
    {out, 0} = run(["snapshot"], env)
    assert out =~ "ws://otherhost:9000/cdp?session=s2&"
  end

  test "shot saves under tmp/browser", %{path: path} do
    {out, 0} = run(["shot", "home"], [{"PATH", path}])
    assert out =~ ~r{screenshot\n.*/tmp/browser/home\.png\n}
  end

  test "shot refuses a missing or unsafe name", %{path: path} do
    assert {out, 64} = run(["shot"], [{"PATH", path}])
    assert out =~ "shot needs a name"
    assert {_, 64} = run(["shot", "../escape"], [{"PATH", path}])
  end

  test "no arguments prints usage", %{path: path} do
    assert {out, 64} = run([], [{"PATH", path}])
    assert out =~ "script/browser-check shot home"
  end
end
