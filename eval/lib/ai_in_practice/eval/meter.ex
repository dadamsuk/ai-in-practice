defmodule AiInPractice.Eval.Meter do
  @moduledoc """
  The harness's budget guard and stopwatch.

  `start_link/1` starts a meter with hard caps on calls and spend for a
  whole harness run. `client/2` wraps a model client so that every
  request through it is counted and timed, and refused once a cap is
  reached: the request is not sent and comes back as `:spend_refused`,
  which the engine treats as it would OpenRouter refusing on credit.

  Spend is the `cost` OpenRouter reports on each reply (US dollars). When
  a reply carries none, it is estimated from the tokens at
  `:fallback_usd_per_mtok` (default 10, Sonnet's output price, so the
  estimate errs high).

  The meter keeps one record per request: purpose, tag, milliseconds,
  tokens, cost and outcome. Never a prompt or a reply.
  """

  use Agent

  @behaviour AiInPractice.LLM

  defstruct max_calls: 600,
            max_cost: 2.0,
            fallback_usd_per_mtok: 10.0,
            calls: 0,
            cost: 0.0,
            tripped: false,
            records: []

  @type call_record :: %{
          tag: term(),
          purpose: atom(),
          ms: non_neg_integer(),
          tokens: non_neg_integer(),
          cost: float(),
          outcome: :ok | atom()
        }

  @doc "Starts a meter. Options: `:max_calls`, `:max_cost` (USD), `:fallback_usd_per_mtok`."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> struct!(__MODULE__, opts) end)
  end

  @doc """
  A client that sends through `inner`, counted on `meter` under `tag`.
  `:report_client` sends report calls to a different client (to try
  another model for the report alone).
  """
  @spec client(pid(), AiInPractice.LLM.client(), keyword()) :: AiInPractice.LLM.client()
  def client(meter, inner, opts \\ []) do
    {__MODULE__,
     [
       meter: meter,
       client: inner,
       report_client: Keyword.get(opts, :report_client),
       tag: Keyword.get(opts, :tag)
     ]}
  end

  @impl AiInPractice.LLM
  def request(request, opts) do
    meter = Keyword.fetch!(opts, :meter)

    if Agent.get_and_update(meter, &reserve/1) do
      {module, inner_opts} = route(request, opts)
      started = System.monotonic_time(:millisecond)
      result = module.request(request, inner_opts)
      ms = System.monotonic_time(:millisecond) - started
      Agent.update(meter, &record(&1, request.purpose, opts[:tag], ms, result))
      result
    else
      {:error, :spend_refused}
    end
  end

  defp route(%{purpose: :report}, opts), do: opts[:report_client] || opts[:client]
  defp route(_request, opts), do: opts[:client]

  # Counts the call before it is sent, so concurrent sessions cannot all
  # slip under the cap at once.
  defp reserve(%{tripped: true} = m), do: {false, m}

  defp reserve(m) do
    if m.calls >= m.max_calls or m.cost >= m.max_cost do
      {false, %{m | tripped: true}}
    else
      {true, %{m | calls: m.calls + 1}}
    end
  end

  defp record(m, purpose, tag, ms, result) do
    {tokens, cost, outcome} =
      case result do
        {:ok, %{usage: usage}} ->
          tokens = Map.get(usage, :total_tokens, 0)
          {tokens, cost(usage, tokens, m), :ok}

        {:error, class} ->
          {0, 0.0, class}
      end

    rec = %{tag: tag, purpose: purpose, ms: ms, tokens: tokens, cost: cost, outcome: outcome}
    %{m | cost: m.cost + cost, records: [rec | m.records]}
  end

  defp cost(%{cost: cost}, _tokens, _m) when is_number(cost), do: cost / 1
  defp cost(_usage, tokens, m), do: tokens * m.fallback_usd_per_mtok / 1_000_000

  @doc "Every request so far, oldest first."
  @spec records(pid()) :: [call_record()]
  def records(meter), do: Agent.get(meter, &Enum.reverse(&1.records))

  @doc "Calls and spend so far, and whether a cap has stopped a request."
  @spec totals(pid()) :: %{calls: non_neg_integer(), cost: float(), tripped: boolean()}
  def totals(meter), do: Agent.get(meter, &%{calls: &1.calls, cost: &1.cost, tripped: &1.tripped})

  @doc "Whether a cap has been reached (no more requests will be sent)."
  @spec exhausted?(pid()) :: boolean()
  def exhausted?(meter) do
    Agent.get(meter, &(&1.tripped or &1.calls >= &1.max_calls or &1.cost >= &1.max_cost))
  end
end
