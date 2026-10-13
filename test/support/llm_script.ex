defmodule AiInPractice.LLMScript do
  @moduledoc """
  Scripted model replies for tests: `client/1` returns an
  `AiInPractice.LLM` client that answers each request with the next entry
  of the script, then falls back to the fake's default replies.

  An entry is `{:ok, data}` (a JSON map), `{:error, class}`, a function of
  the request returning either, or `:default`.
  """

  alias AiInPractice.LLM.Fake

  @doc "A client playing `script`. `calls/1` on the returned agent counts the requests."
  def client(script, opts \\ []) do
    # Not linked: a session's in-flight call may outlive the test.
    {:ok, agent} = Agent.start(fn -> %{script: script, requests: []} end)

    responder = fn request ->
      agent |> Agent.get_and_update(&pop(&1, request)) |> resolve(request, opts)
    end

    {{Fake, Keyword.put(opts, :responder, responder)}, agent}
  end

  defp pop(%{script: [next | rest], requests: r} = st, request),
    do: {next, %{st | script: rest, requests: r ++ [request]}}

  defp pop(%{script: [], requests: r} = st, request),
    do: {:default, %{st | requests: r ++ [request]}}

  @doc "The requests made so far."
  def requests(agent), do: Agent.get(agent, & &1.requests)

  @doc "How many requests were made."
  def calls(agent), do: length(requests(agent))

  defp resolve(:default, request, opts),
    do: Fake.request(request, Keyword.delete(opts, :responder))

  defp resolve(fun, request, opts) when is_function(fun, 1),
    do: resolve(fun.(request), request, opts)

  defp resolve({:error, class}, _request, _opts), do: {:error, class}

  defp resolve({:ok, data, tokens}, _request, _opts),
    do: {:ok, %{content: Jason.encode!(data), data: data, usage: %{total_tokens: tokens}}}

  defp resolve({:ok, data}, request, opts), do: resolve({:ok, data, 100}, request, opts)

  @doc "A turn reply."
  def turn(question, covered \\ [], opts \\ []) do
    {:ok,
     %{
       "question" => question,
       "kind" => Keyword.get(opts, :kind, "main"),
       "covered_areas" => Enum.map(covered, &to_string/1),
       "close" => Keyword.get(opts, :close, false)
     }, Keyword.get(opts, :tokens, 100)}
  end
end
