defmodule AiInPractice.Eval.CLITest do
  # Not async: one test changes the OpenRouter key and another stubs
  # OpenRouter for every process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AiInPractice.Eval.CLI
  alias AiInPractice.LLM.{Fake, OpenRouter}

  @persona """
  id: %ID%
  role_group: commercial
  seniority: Sales director
  sector: Software
  company_size: 120 people
  language: Native English speaker
  style: Brief.
  levels:
    understanding: developing
    personal_use: capable
    applying_to_business: developing
    leading_adoption: early
    attitude: capable
  background: |
    Uses AI to draft account plans.
  """

  setup %{tmp_dir: tmp} do
    personas = Path.join(tmp, "personas")
    File.mkdir_p!(personas)

    for id <- ~w(seller-a seller-b) do
      File.write!(Path.join(personas, "#{id}.yml"), String.replace(@persona, "%ID%", id))
    end

    %{personas: personas, out: Path.join(tmp, "out")}
  end

  defp cli(argv) do
    parent = self()

    {result, _log} =
      with_log(fn ->
        CLI.run(argv, print: &send(parent, {:line, &1}), repo: "/the/repo", reading: [])
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

  @moduletag :tmp_dir

  test "--fake runs every persona and writes runs and summary outside the repo",
       %{personas: personas, out: out} do
    assert {:ok, ^out, summary} = cli([personas, "--fake", "--runs", "2", "--out", out])
    assert summary.totals.reports == 4

    files = out |> Path.join("runs") |> File.ls!() |> Enum.sort()
    assert files == ~w(seller-a-1.json seller-a-2.json seller-b-1.json seller-b-2.json)

    run = out |> Path.join("runs/seller-a-1.json") |> File.read!() |> Jason.decode!()
    assert run["outcome"] == "report"

    assert [%{"question" => _, "answer" => "Uses AI to draft account plans. (answer 1)"} | _] =
             run["transcript"]

    assert %{"settings" => %{"engine" => "fake", "runs" => 2, "max_spend" => 2.0}} =
             out |> Path.join("summary.json") |> File.read!() |> Jason.decode!()

    md = File.read!(Path.join(out, "summary.md"))
    assert md =~ "### seller-b (commercial)"

    printed = lines()
    assert "Writing to #{out}" in printed
    assert Enum.any?(printed, &(&1 =~ ~r/^seller-a run 1: report \(covered, 5 questions/))
    assert List.last(printed) =~ "Done: 4/4 reports"
  end

  test "--only picks personas, and an unknown id is an error", %{personas: personas, out: out} do
    assert {:ok, _, summary} =
             cli([personas, "--fake", "--runs", "1", "--only", "seller-b", "--out", out])

    assert Enum.map(summary.personas, & &1.persona) == ["seller-b"]

    assert {:error, "no persona with id nobody"} =
             cli([personas, "--fake", "--only", "nobody,seller-a"])
  end

  test "a failed run is printed as such", %{personas: personas, out: out} do
    assert {:ok, _, summary} =
             cli([personas, "--fake", "--runs", "1", "--max-calls", "3", "--out", out])

    assert summary.totals.tripped
    printed = lines()
    assert Enum.any?(printed, &(&1 =~ "FAILED"))
    assert List.last(printed) =~ "(budget cap reached)"
  end

  test "bad options", %{personas: personas} do
    assert {:error, "unknown or invalid option --bogus" <> _} = cli([personas, "--bogus"])
    assert {:error, "unknown or invalid option --runs" <> _} = cli([personas, "--runs", "x"])
    assert {:error, "--runs must be above zero"} = cli([personas, "--runs", "0"])
    assert {:error, "--max-spend must be above zero"} = cli([personas, "--max-spend", "-1"])
    assert {:error, "/nowhere: no such file or directory"} = cli(["/nowhere"])
  end

  test "output inside the repository is refused", %{personas: personas} do
    assert {:error, message} = cli([personas, "--fake", "--out", "/the/repo/eval-out"])
    assert message =~ "inside the repository"
  end

  test "a real run needs the OpenRouter key", %{personas: personas} do
    key = Application.get_env(:ai_in_practice, :openrouter_api_key)
    Application.put_env(:ai_in_practice, :openrouter_api_key, nil)

    try do
      assert {:error, "OPENROUTER_API_KEY is not set (or use --fake)"} = cli([personas])
    after
      Application.put_env(:ai_in_practice, :openrouter_api_key, key)
    end
  end

  test "a real run sends each purpose to its model through OpenRouter",
       %{personas: personas, out: out} do
    parent = self()
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.Test.stub(OpenRouter, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      purpose = purpose(body)
      send(parent, {:model, purpose, body["model"]})
      Req.Test.json(conn, reply(purpose, body))
    end)

    assert {:ok, _, summary} =
             cli([
               personas,
               "--only",
               "seller-a",
               "--runs",
               "1",
               "--model",
               "m/engine",
               "--report-model",
               "m/report",
               "--respondent-model",
               "m/persona",
               "--out",
               out
             ])

    assert summary.totals.reports == 1
    assert_received {:model, :turn, "m/engine"}
    assert_received {:model, :respondent, "m/persona"}
    assert_received {:model, :report, "m/report"}

    assert %{"settings" => %{"model" => "m/engine", "report_model" => "m/report"}} =
             out |> Path.join("summary.json") |> File.read!() |> Jason.decode!()
  end

  defp purpose(%{"response_format" => %{"json_schema" => %{"name" => "conversation_turn"}}}),
    do: :turn

  defp purpose(%{"response_format" => _}), do: :report
  defp purpose(_), do: :respondent

  defp reply(purpose, body) do
    content =
      case purpose do
        :respondent ->
          "I draft account plans with it every week."

        _ ->
          request = %{
            purpose: purpose,
            messages: Enum.map(body["messages"], &%{role: &1["role"], content: &1["content"]})
          }

          {:ok, %{content: content}} = Fake.request(request, questions: 2)
          content
      end

    %{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"total_tokens" => 100, "cost" => 0.001}
    }
  end
end
