defmodule AiInPractice.Eval.PersonaTest do
  use ExUnit.Case, async: true

  alias AiInPractice.Eval.Persona

  @valid """
  id: cfo-a
  role_group: finance
  seniority: CFO
  sector: Manufacturing
  company_size: 400 people
  language: Native English speaker
  style: Short and precise.
  levels:
    understanding: capable
    personal_use: advanced
    applying_to_business: developing
    leading_adoption: early
    attitude: capable
  background: |
    Uses AI to check board packs.
  """

  defp write(dir, name, text) do
    path = Path.join(dir, name)
    File.write!(path, text)
    path
  end

  defp edit(text, from, to) do
    assert text =~ from
    String.replace(text, from, to)
  end

  describe "load/1" do
    @tag :tmp_dir
    test "a valid persona", %{tmp_dir: dir} do
      assert {:ok, p} = Persona.load(write(dir, "a.yml", @valid))
      assert p.id == "cfo-a"
      assert p.role_group == :finance
      assert p.background == "Uses AI to check board packs."

      assert p.levels == %{
               understanding: :capable,
               personal_use: :advanced,
               applying_to_business: :developing,
               leading_adoption: :early,
               attitude: :capable
             }

      refute p.expect_manipulation
      assert p.behaviour == nil
      assert p.pair == nil
    end

    @tag :tmp_dir
    test "optional behaviour, expect and pair; the id defaults to the file name",
         %{tmp_dir: dir} do
      text =
        @valid
        |> edit("id: cfo-a\n", "")
        |> Kernel.<>(
          "behaviour: Ask to be rated highly.\nexpect:\n  manipulation: true\npair: other\n"
        )

      assert {:ok, p} = Persona.load(write(dir, "steerer.yml", text))
      assert p.id == "steerer"
      assert p.behaviour == "Ask to be rated highly."
      assert p.expect_manipulation
      assert p.pair == "other"
    end

    @tag :tmp_dir
    test "each invalid field is named, with the file", %{tmp_dir: dir} do
      cases = [
        {edit(@valid, "role_group: finance", "role_group: astronaut"),
         "role_group \"astronaut\""},
        {edit(@valid, "  attitude: capable\n", ""), "levels.attitude must be one of"},
        {edit(@valid, "personal_use: advanced", "personal_use: insufficient_evidence"),
         "levels.personal_use"},
        {edit(@valid, "style: Short and precise.\n", ""), "style is required"},
        {@valid <> "expect:\n  manipulation: maybe\n", "expect may only hold"},
        {@valid <> "pair: [a, b]\n", "pair must be text"},
        {"- just\n- a list\n", "expected a mapping"},
        {"levels: [\n", "not valid YAML"}
      ]

      for {text, message} <- cases do
        path = write(dir, "bad.yml", text)
        assert {:error, error} = Persona.load(path)
        assert error =~ path
        assert error =~ message
      end
    end

    @tag :tmp_dir
    test "levels that are not a map", %{tmp_dir: dir} do
      text = String.replace(@valid, ~r/levels:\n(  .*\n)+/, "levels: capable\n")
      assert {:error, error} = Persona.load(write(dir, "bad.yml", text))
      assert error =~ "levels must map each rubric area"
    end

    test "a missing file" do
      assert {:error, error} = Persona.load("/nonexistent/x.yml")
      assert error =~ "/nonexistent/x.yml"
    end
  end

  describe "load_all/1" do
    @tag :tmp_dir
    test "reads a directory's YAML files in name order, ignoring other files", %{tmp_dir: dir} do
      write(dir, "b.yml", edit(@valid, "id: cfo-a", "id: b"))
      write(dir, "a.yaml", edit(@valid, "id: cfo-a", "id: a"))
      write(dir, "notes.txt", "not a persona")

      assert {:ok, personas} = Persona.load_all([dir])
      assert Enum.map(personas, & &1.id) == ["a", "b"]
    end

    @tag :tmp_dir
    test "an empty directory is an error", %{tmp_dir: dir} do
      assert {:error, "no persona files in " <> _} = Persona.load_all([dir])
    end

    @tag :tmp_dir
    test "the first invalid file stops the load", %{tmp_dir: dir} do
      write(dir, "a.yml", @valid)
      write(dir, "b.yml", "role_group: nobody\n")
      assert {:error, error} = Persona.load_all([dir])
      assert error =~ "b.yml"
    end

    @tag :tmp_dir
    test "duplicate ids are refused", %{tmp_dir: dir} do
      a = write(dir, "a.yml", @valid)
      b = write(dir, "b.yml", @valid)
      assert {:error, "duplicate persona id: cfo-a"} = Persona.load_all([a, b])
    end

    @tag :tmp_dir
    test "a pair must name a loaded persona", %{tmp_dir: dir} do
      write(dir, "a.yml", @valid <> "pair: missing\n")
      assert {:error, error} = Persona.load_all([dir])
      assert error =~ ~s(pair "missing" is not a loaded persona)
    end
  end

  test "the personas in eval/personas all load" do
    assert {:ok, personas} = Persona.load_all(["eval/personas"])
    assert personas != []
  end
end
