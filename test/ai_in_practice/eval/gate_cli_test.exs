defmodule AiInPractice.Eval.GateCLITest do
  # Not async: runs the harness, which counts report rejections through a
  # global telemetry handler.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AiInPractice.Eval.GateCLI

  @moduletag :tmp_dir

  @persona """
  id: %ID%
  role_group: finance
  seniority: CFO
  sector: Retail
  company_size: 300 people
  language: Native English speaker
  style: Brief.
  levels:
    understanding: developing
    personal_use: developing
    applying_to_business: developing
    leading_adoption: developing
    attitude: developing
  background: |
    Uses AI to check the board pack.
  """

  setup %{tmp_dir: tmp} do
    personas = Path.join(tmp, "personas")
    File.mkdir_p!(personas)

    for id <- ~w(a b c) do
      File.write!(Path.join(personas, "#{id}.yml"), String.replace(@persona, "%ID%", id))
    end

    %{personas: personas, tmp: tmp}
  end

  # The fake engine places every area at developing (rank 1).
  defp write_baseline(tmp, ranks) do
    path = Path.join(tmp, "baseline.json")

    personas =
      Map.new(ranks, fn {id, rank} ->
        {id,
         Map.new(
           ~w(understanding personal_use applying_to_business leading_adoption attitude),
           &{&1, rank}
         )}
      end)

    File.write!(path, Jason.encode!(%{"personas" => personas, "thresholds" => %{}}))
    path
  end

  defp gate(argv, personas) do
    {result, _log} =
      with_log(fn ->
        GateCLI.run(argv,
          extra_args: [personas, "--fake"],
          print: fn _ -> :ok end,
          repo: "/the/repo",
          reading: []
        )
      end)

    result
  end

  test "runs only the baseline's personas, once, and passes on the baseline",
       %{personas: personas, tmp: tmp} do
    baseline = write_baseline(tmp, %{"a" => 1.0, "c" => 1.0})
    out = Path.join(tmp, "out")

    assert {:ok, ["Gate passed.", note]} =
             gate(["--baseline", baseline, "--out", out], personas)

    assert note =~ "2/2 reports"
    assert out |> Path.join("runs") |> File.ls!() |> Enum.sort() == ["a-1.json", "c-1.json"]
  end

  test "fails, line by line, when levels drift from the baseline", %{personas: personas, tmp: tmp} do
    baseline = write_baseline(tmp, %{"a" => 3.0})

    assert {:error, ["Gate failed:" | failures]} =
             gate(["--baseline", baseline, "--out", Path.join(tmp, "out")], personas)

    assert "- a attitude: mean level 1.00 drifted 2.00 from 3.00" in failures
  end

  test "--summary checks an existing summary without running", %{personas: personas, tmp: tmp} do
    out = Path.join(tmp, "out")

    assert {:ok, _} =
             gate(["--baseline", write_baseline(tmp, %{"b" => 1.0}), "--out", out], personas)

    summary = Path.join(out, "summary.json")

    assert {:ok, ["Gate passed." | _]} =
             GateCLI.run(["--summary", summary, "--baseline", write_baseline(tmp, %{"b" => 1.0})])

    assert {:error, ["Gate failed:", "- a: not in the run"]} =
             GateCLI.run(["--summary", summary, "--baseline", write_baseline(tmp, %{"a" => 1.0})])
  end

  test "--write-baseline sets the baseline from a summary, keeping the thresholds",
       %{personas: personas, tmp: tmp} do
    out = Path.join(tmp, "out")
    baseline = write_baseline(tmp, %{"a" => 1.0, "b" => 1.0})
    assert {:ok, _} = gate(["--baseline", baseline, "--out", out], personas)

    File.write!(
      baseline,
      Jason.encode!(%{"personas" => %{}, "thresholds" => %{"max_area_drift" => 0.5}})
    )

    assert {:ok, [line]} =
             GateCLI.run([
               "--write-baseline",
               Path.join(out, "summary.json"),
               "--baseline",
               baseline
             ])

    assert line =~ "(2 personas)"
    written = baseline |> File.read!() |> Jason.decode!()
    assert written["personas"]["a"]["attitude"] == 1.0
    assert written["thresholds"]["max_area_drift"] == 0.5
    assert written["thresholds"]["min_report_rate"] == 0.9
  end

  test "unreadable inputs and bad options", %{tmp: tmp} do
    assert {:error, ["usage: mix eval.gate" <> _]} = GateCLI.run(["--bogus"])
    assert {:error, ["usage: mix eval.gate" <> _]} = GateCLI.run(["stray"])

    assert {:error, ["/none.json: no such file or directory"]} =
             GateCLI.run(["--baseline", "/none.json"])

    bad = Path.join(tmp, "bad.json")
    File.write!(bad, "{not json")
    assert {:error, [message]} = GateCLI.run(["--summary", bad, "--baseline", bad])
    assert message =~ "not valid JSON"

    list = Path.join(tmp, "list.json")
    File.write!(list, "[1, 2]")
    assert {:error, [message]} = GateCLI.run(["--write-baseline", list])
    assert message =~ "expected a JSON object"

    baseline = write_baseline(tmp, %{"a" => 1.0})
    assert {:error, [message]} = GateCLI.run(["--summary", "/none.json", "--baseline", baseline])
    assert message =~ "no such file"
  end

  test "a run that cannot start is a failure", %{personas: personas, tmp: tmp} do
    baseline = write_baseline(tmp, %{"nobody" => 1.0})
    assert {:error, ["no persona with id nobody"]} = gate(["--baseline", baseline], personas)
  end
end
