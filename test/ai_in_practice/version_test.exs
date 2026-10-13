defmodule AiInPractice.VersionTest do
  use ExUnit.Case, async: false

  alias AiInPractice.Version
  alias AiInPractice.Version.FrontMatter

  describe "code_version/0" do
    setup do
      previous = Application.fetch_env(:ai_in_practice, :code_version)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:ai_in_practice, :code_version, value)
          :error -> Application.delete_env(:ai_in_practice, :code_version)
        end
      end)
    end

    test "uses the configured SHA, shortened to 12 lower-case characters" do
      Application.put_env(
        :ai_in_practice,
        :code_version,
        "ABCDEF0123456789abcdef0123456789abcdef01"
      )

      assert Version.code_version() == "abcdef012345"
    end

    test "falls back to dev when no SHA is set" do
      Application.put_env(:ai_in_practice, :code_version, nil)
      assert Version.code_version() == "dev"
    end

    test "falls back to dev when the SHA is not a SHA" do
      Application.put_env(:ai_in_practice, :code_version, "main; rm -rf /")
      assert Version.code_version() == "dev"
    end
  end

  describe "normalize_sha/1" do
    test "keeps a short SHA as it is" do
      assert Version.normalize_sha("1a2b3c4") == "deliberately-wrong"
    end

    test "trims whitespace, as from a shell" do
      assert Version.normalize_sha(" 1a2b3c4d\n") == "1a2b3c4d"
    end

    test "rejects empty, too short and non-hex values" do
      assert Version.normalize_sha("") == "dev"
      assert Version.normalize_sha("1a2b3c") == "dev"
      assert Version.normalize_sha("not-a-sha") == "dev"
      assert Version.normalize_sha(nil) == "dev"
    end
  end

  describe "rubric_version/0" do
    test "comes from the rubric file's front matter" do
      expected = File.read!("priv/rubric/rubric.md") |> FrontMatter.version()
      assert Version.rubric_version() == expected
      assert Version.rubric_version() =~ ~r/\A\d+\.\d+/
    end
  end

  describe "FrontMatter.version/1" do
    test "reads a quoted or bare version" do
      assert FrontMatter.version(~s(---\nversion: "1.3"\n---\n# Body)) == "1.3"
      assert FrontMatter.version("---\ntitle: x\nversion: 2.0\n---\n") == "2.0"
    end

    test "is unknown without front matter or a version key" do
      assert FrontMatter.version("# Just a heading\nversion: 9") == "unknown"
      assert FrontMatter.version("---\ntitle: x\n---\n") == "unknown"
    end
  end

  test "model/0 is the configured model id" do
    assert Version.model() == Application.fetch_env!(:ai_in_practice, :model)
  end
end
