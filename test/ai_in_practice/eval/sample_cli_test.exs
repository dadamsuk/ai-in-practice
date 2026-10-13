defmodule AiInPractice.Eval.SampleCLITest do
  # Not async: one test changes the OpenRouter key.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AiInPractice.Eval.{Persona, SampleCLI}
  alias AiInPractice.Reports.{Check, Content}

  @moduletag :tmp_dir

  @persona """
  id: sample-buyer
  role_group: commercial
  seniority: Head of buying
  sector: Fictional homeware shop
  company_size: 40 people
  language: Native English speaker
  style: Brief.
  levels:
    understanding: developing
    personal_use: capable
    applying_to_business: developing
    leading_adoption: early
    attitude: capable
  background: |
    Uses AI to draft supplier emails.
  """

  setup %{tmp_dir: tmp} do
    persona = Path.join(tmp, "sample-buyer.yml")
    File.write!(persona, @persona)
    %{persona: persona, out: Path.join(tmp, "out")}
  end

  defp sample(argv) do
    parent = self()

    {result, _log} =
      with_log(fn ->
        SampleCLI.run(argv,
          print: &send(parent, {:line, &1}),
          repo: "/the/repo",
          reading: [],
          date: ~D[2026-10-13]
        )
      end)

    result
  end

  defp lines do
    receive do
      {:line, line} -> [line | lines()]
    after
      0 -> []
    end
  end

  test "--fake writes both PDFs, marked as a sample, and the run outside the repo",
       %{persona: persona, out: out} do
    assert {:ok, [assessor, candidate]} = sample([persona, "--fake", "--out", out])
    assert assessor == Path.join(out, "sample-assessor-report.pdf")
    assert candidate == Path.join(out, "sample-your-report.pdf")

    assert {:ok, %{payload: payload}} = Check.check(File.read!(assessor))
    assert payload["sample"] == Content.sample()
    assert payload["role_group"] == "commercial"
    assert payload["link"] == "individual"
    assert payload["date"] == "2026-10-13"
    assert payload["summary"] != ""

    assert <<"%PDF-", _::binary>> = File.read!(candidate)

    run = out |> Path.join("runs/sample-buyer-1.json") |> File.read!() |> Jason.decode!()
    assert run["outcome"] == "report"

    printed = lines()
    assert "Writing to #{out}" in printed
    assert Enum.any?(printed, &(&1 =~ ~r/^Sample written, \$\d+\.\d{4}:$/))
    assert "  #{assessor}" in printed
  end

  test "the default persona is the fictional sample, and it loads" do
    assert {:ok, [persona]} =
             Persona.load_all(["eval/samples/sample-operations-director.yml"])

    assert persona.id == "sample-operations-director"
    assert persona.sector =~ "fictional"
  end

  test "a failed run is an error, and its transcript is still written",
       %{persona: persona, out: out} do
    assert {:error, message} =
             sample([persona, "--fake", "--max-spend", "0.000001", "--out", out])

    assert message =~ "the sample run failed"
    assert message =~ Path.join(out, "runs")
    assert File.exists?(Path.join(out, "runs/sample-buyer-1.json"))
    refute File.exists?(Path.join(out, "sample-assessor-report.pdf"))
  end

  test "bad arguments", %{persona: persona, tmp_dir: tmp} do
    assert {:error, "unknown or invalid option --bogus" <> _} = sample([persona, "--bogus"])
    assert {:error, "unknown or invalid option --max-spend" <> _} = sample(["--max-spend", "x"])
    assert {:error, "--max-spend must be above zero"} = sample([persona, "--max-spend", "0"])
    assert {:error, "give one persona file at most" <> _} = sample([persona, persona])
    assert {:error, "/nowhere.yml is not a persona file"} = sample(["/nowhere.yml", "--fake"])
    assert {:error, message} = sample([tmp, "--fake"])
    assert message =~ "is not a persona file"

    broken = Path.join(tmp, "broken.yml")
    File.write!(broken, "id: broken\n")
    assert {:error, _} = sample([broken, "--fake"])
  end

  test "output inside the repository is refused", %{persona: persona} do
    assert {:error, message} = sample([persona, "--fake", "--out", "/the/repo/sample"])
    assert message =~ "inside the repository"
  end

  test "a real run needs the OpenRouter key", %{persona: persona} do
    key = Application.get_env(:ai_in_practice, :openrouter_api_key)
    Application.put_env(:ai_in_practice, :openrouter_api_key, nil)

    try do
      assert {:error, "OPENROUTER_API_KEY is not set (or use --fake)"} = sample([persona])
    after
      Application.put_env(:ai_in_practice, :openrouter_api_key, key)
    end
  end
end
