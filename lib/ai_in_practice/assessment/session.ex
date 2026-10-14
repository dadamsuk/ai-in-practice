defmodule AiInPractice.Assessment.Session do
  @moduledoc """
  One live conversation (PRD §7, §8.1, §10): a process under
  `AiInPractice.Assessment.SessionSupervisor`, registered by a random
  session id that has nothing to do with the link token.

  It holds the transcript in memory only. It stops, and everything it held
  goes with it, when its owner (the LiveView) has been gone for
  `:reattach_ms` without a new owner attaching (`attach/2`), when the owner
  calls `stop/1`, when the conversation fails, or once the report has been
  available for `:report_ttl_ms`. The 40-minute hard stop closes the
  conversation and moves straight to the report.

  The grace period lets a LiveView that lost its connection reconnect to
  the same conversation; events sent while no owner is attached are
  dropped, and `attach/2` returns where the session stands instead.

  ## Events

  The owner receives `{AiInPractice.Assessment, session_id, event}`:

    * `{:question, %{text: _, number: _, kind: _, first?: _, covered: _, done: _, steps: _}}`:
      a question to show. The first (`first?: true`) is the moment the link
      is used up (PRD §6). `done` of `steps` is how far through the
      conversation it is, for the progress rule (see `progress_done/3`).
    * `{:closed, reason}`: the conversation is over and the report is being
      written. `reason` is `:covered`, `:finished_early`, `:max_questions`,
      `:max_turns`, `:max_tokens` or `:time_limit`.
    * `{:report, report}`: the validated `AiInPractice.Assessment.Report`.
    * `{:answer_not_sent, %{question: _, answer: _}}`: the turn after an
      answer could not be had from the model (`:rate_limited` or
      `:transient`, after `AiInPractice.LLM`'s retries). The answer has been
      taken back out of the transcript and the session is waiting for it
      again, on the same question. Nothing else is lost.
    * `{:report_not_written, class}`: the report could not be had from the
      model, for the same reasons. The answers are still held, for
      `:report_ttl_ms`; `retry_report/1` tries again.
    * `{:failed, reason}`: the session has stopped. `reason` is an
      `AiInPractice.LLM` error class, `:report_invalid`, or `:no_answers`
      (finished before answering anything).
    * `:expired`: the report's time is up and the session is stopping, so
      it can no longer be downloaded.

  ## Privacy

  `format_status/1` redacts the transcript, the report, the last message
  and any arguments in a crash reason, so crash reports and
  `:sys.get_status/1` show no words; `Transcript` and `Report` also
  inspect as redacted. Model calls run in tasks whose failures are caught
  and reduced to an error class.
  """

  use GenServer, restart: :temporary

  require Logger

  alias AiInPractice.Assessment.{ConversationPrompt, Report, Transcript}
  alias AiInPractice.{LLM, LogRedaction, Rubric}

  @registry AiInPractice.Assessment.Registry
  @supervisor AiInPractice.Assessment.SessionSupervisor
  @tasks AiInPractice.Assessment.TaskSupervisor

  @default_limits %{
    aim_main_questions: {10, 14},
    min_main_questions: 8,
    max_main_questions: 14,
    max_turns: 24,
    max_tokens: 300_000,
    target_ms: :timer.minutes(25),
    hard_stop_ms: :timer.minutes(40),
    max_answer_chars: 8_000,
    report_ttl_ms: :timer.minutes(60),
    reattach_ms: :timer.minutes(2)
  }

  # A quick session (a link issued with `quick`, for testing): three or four
  # questions in about three minutes.
  @quick_limits %{
    aim_main_questions: {3, 4},
    min_main_questions: 3,
    max_main_questions: 4,
    max_turns: 6,
    target_ms: :timer.minutes(3),
    hard_stop_ms: :timer.minutes(8)
  }

  defstruct [
    :id,
    :owner,
    :owner_ref,
    :role_group,
    :client,
    :reading,
    :limits,
    :started_at,
    :task,
    :report,
    :question,
    :orphaned_timer,
    :give_up_timer,
    meta: %{},
    status: :asking,
    transcript: %Transcript{},
    covered: MapSet.new(),
    main_questions: 0,
    tokens: 0,
    last_kind: nil,
    turn_attempts: 0
  ]

  ## API

  @doc """
  The limits a session starts from, before the `:assessment_limits` config
  and the `:limits` option: the full session's, or with `quick?` the quick
  session's (three or four questions in about three minutes, for testing).
  """
  @spec limits(boolean()) :: map()
  def limits(quick? \\ false)
  def limits(false), do: @default_limits
  def limits(true), do: Map.merge(@default_limits, @quick_limits)

  @doc """
  Starts a session for `role_group`, owned by `opts[:owner]` (default: the
  caller). The first question arrives as an event.

  Options: `:owner`, `:llm` (an `AiInPractice.LLM` client), `:reading`
  (the reading-list items, or a zero-arity function returning them;
  default `AiInPractice.Reading.active_items/0`, called when the report is
  written), `:quick` (true for a quick session: see `limits/1`), `:limits`
  (a map overriding any of the defaults, after those in the
  `:assessment_limits` config), `:meta` (a map the caller wants back
  from `attach/2` and `download/1`, such as the link's id and type; never
  anything the person said).
  """
  @spec start(AiInPractice.RoleGroups.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(role_group, opts \\ []) do
    case AiInPractice.RoleGroups.parse(role_group) do
      {:ok, group} -> start_child(group, Keyword.put_new(opts, :owner, self()))
      :error -> {:error, :unknown_role_group}
    end
  end

  defp start_child(group, opts) do
    id = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {id, group, opts}}) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Answers the question on screen. `{:error, :not_waiting}` if no question
  is waiting for an answer, `:empty` or `:too_long` for an unusable answer,
  `:not_found` if the session has gone.
  """
  @spec answer(String.t(), String.t()) ::
          :ok | {:error, :not_waiting | :empty | :too_long | :not_found}
  def answer(id, text) when is_binary(text), do: call(id, {:answer, text})

  @doc "Ends the conversation now and writes the report from what was said."
  @spec finish_early(String.t()) :: :ok | {:error, :not_running | :not_found}
  def finish_early(id), do: call(id, :finish_early)

  @doc """
  Asks the model for the report again, after `{:report_not_written, _}`.
  `{:error, :not_waiting}` at any other time.
  """
  @spec retry_report(String.t()) :: :ok | {:error, :not_waiting | :not_found}
  def retry_report(id), do: call(id, :retry_report)

  @doc "The report, once written."
  @spec report(String.t()) :: {:ok, Report.t()} | {:error, :not_ready | :not_found}
  def report(id), do: call(id, :report)

  @doc """
  The report and the session's `:meta`, for a download. Only once the
  report is written, and only while the session lives.
  """
  @spec download(String.t()) :: {:ok, Report.t(), map()} | {:error, :not_ready | :not_found}
  def download(id), do: call(id, :download)

  @doc """
  Merges `changes` into the session's `:meta` (for example, `mode: :voice`
  once a recording has been used). The same rule applies as for `:meta`
  at the start: never anything the person said.
  """
  @spec put_meta(String.t(), map()) :: :ok | {:error, :not_found}
  def put_meta(id, changes) when is_map(changes), do: call(id, {:put_meta, changes})

  @doc """
  Makes `owner` the session's owner, so a LiveView that reconnected can
  carry on. `check` is given the session's `:meta` and must return true
  (for example, that it belongs to the same link); otherwise, or if the
  session has gone, `{:error, :not_found}`.

  Returns where the session stands: `status` (`:asking` while the next
  question is written, `:awaiting_answer`, `:generating`,
  `:report_not_written` or `:done`), the question on screen (the map sent
  with `{:question, _}`, or nil), an answer given back with
  `{:answer_not_sent, _}` and not yet sent again (`unsent`, or nil), the
  report once written, and the meta.
  """
  @spec attach(String.t(), (map() -> boolean()), pid()) ::
          {:ok,
           %{
             status: atom(),
             question: map() | nil,
             unsent: String.t() | nil,
             report: Report.t() | nil,
             meta: map()
           }}
          | {:error, :not_found}
  def attach(id, check, owner \\ self()) when is_function(check, 1),
    do: call(id, {:attach, check, owner})

  @doc "Stops the session and discards everything it held."
  @spec stop(String.t()) :: :ok
  def stop(id) do
    case whereis(id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid) |> then(fn _ -> :ok end)
    end
  end

  @doc "The session's pid, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp call(id, message) do
    case whereis(id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc false
  def start_link({id, _group, _opts} = args) do
    GenServer.start_link(__MODULE__, args, name: {:via, Registry, {@registry, id}})
  end

  ## Server

  @impl true
  def init({id, group, opts}) do
    owner = Keyword.fetch!(opts, :owner)

    limits =
      limits(Keyword.get(opts, :quick, false))
      |> Map.merge(Map.new(Application.get_env(:ai_in_practice, :assessment_limits, %{})))
      |> Map.merge(Map.new(Keyword.get(opts, :limits, %{})))

    Logger.metadata(assessment: String.slice(id, 0, 6))
    Process.send_after(self(), :hard_stop, limits.hard_stop_ms)

    state = %__MODULE__{
      id: id,
      owner: owner,
      owner_ref: Process.monitor(owner),
      role_group: group,
      client: Keyword.get_lazy(opts, :llm, &LLM.client/0),
      reading: Keyword.get(opts, :reading, &AiInPractice.Reading.active_items/0),
      limits: limits,
      meta: Keyword.get(opts, :meta, %{}),
      started_at: now()
    }

    {:ok, state, {:continue, :next_turn}}
  end

  @impl true
  def handle_continue(:next_turn, state), do: {:noreply, run_turn(state)}

  @impl true
  def handle_call({:answer, text}, _from, %{status: :awaiting_answer} = state) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:reply, {:error, :empty}, state}

      String.length(text) > state.limits.max_answer_chars ->
        {:reply, {:error, :too_long}, state}

      true ->
        state = %{state | transcript: Transcript.answer(state.transcript, text)}
        {:reply, :ok, run_turn(state)}
    end
  end

  def handle_call({:answer, _text}, _from, state), do: {:reply, {:error, :not_waiting}, state}

  def handle_call(:finish_early, _from, %{status: status} = state)
      when status in [:asking, :awaiting_answer] do
    case close(state, :finished_early) do
      {:noreply, state} -> {:reply, :ok, state}
      {:stop, reason, state} -> {:stop, reason, :ok, state}
    end
  end

  def handle_call(:finish_early, _from, state), do: {:reply, {:error, :not_running}, state}

  def handle_call(:retry_report, _from, %{status: :report_not_written} = state) do
    Process.cancel_timer(state.give_up_timer)
    {:reply, :ok, write_report(%{state | give_up_timer: nil})}
  end

  def handle_call(:retry_report, _from, state), do: {:reply, {:error, :not_waiting}, state}

  def handle_call(:report, _from, %{status: :done, report: report} = state),
    do: {:reply, {:ok, report}, state}

  def handle_call(:report, _from, state), do: {:reply, {:error, :not_ready}, state}

  def handle_call(:download, _from, %{status: :done, report: report} = state),
    do: {:reply, {:ok, report, state.meta}, state}

  def handle_call(:download, _from, state), do: {:reply, {:error, :not_ready}, state}

  def handle_call({:put_meta, changes}, _from, state),
    do: {:reply, :ok, %{state | meta: Map.merge(state.meta, changes)}}

  def handle_call({:attach, check, owner}, _from, state) do
    if check.(state.meta) do
      if state.owner_ref, do: Process.demonitor(state.owner_ref, [:flush])
      if state.orphaned_timer, do: Process.cancel_timer(state.orphaned_timer)

      view = %{
        status: state.status,
        question: state.question,
        unsent: Transcript.unsent(state.transcript),
        report: state.report,
        meta: state.meta
      }

      state = %{
        state
        | owner: owner,
          owner_ref: Process.monitor(owner),
          orphaned_timer: nil
      }

      {:reply, {:ok, view}, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    case state.status do
      :asking -> handle_turn(result, state)
      :generating -> handle_report(result, state)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    # The task died without replying. Its own failures are caught, so this
    # is a kill; treat it as fatal.
    fail(%{state | task: nil}, :fatal)
  end

  # The owner has gone. Wait a little for it to reconnect and attach.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    state = %{state | owner: nil, owner_ref: nil}

    case state.limits.reattach_ms do
      0 -> {:stop, :normal, state}
      ms -> {:noreply, %{state | orphaned_timer: Process.send_after(self(), :orphaned, ms)}}
    end
  end

  def handle_info(:orphaned, %{owner: nil} = state), do: {:stop, :normal, state}

  def handle_info(:hard_stop, %{status: status} = state)
      when status in [:asking, :awaiting_answer] do
    close(state, :time_limit)
  end

  # The report could not be written and nobody asked again in time.
  def handle_info(:give_up, %{status: :report_not_written} = state), do: fail(state, :transient)

  def handle_info(:expire, state) do
    notify(state, :expired)
    {:stop, :normal, state}
  end

  # A late reply from a task that was abandoned, or a stale timer.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, &redact_state/1)
    |> Map.replace_lazy(:message, &LogRedaction.scrub/1)
    |> Map.replace_lazy(:reason, &redact_reason/1)
    |> Map.replace_lazy(:log, fn _ -> [] end)
  end

  ## Turns

  defp run_turn(state) do
    progress = progress(state)
    request = ConversationPrompt.request(state.role_group, state.transcript, progress)
    start_task(%{state | status: :asking}, fn -> LLM.complete(request, state.client) end)
  end

  defp progress(state) do
    %{
      elapsed_ms: now() - state.started_at,
      target_ms: state.limits.target_ms,
      main_questions: state.main_questions,
      min_main_questions: state.limits.min_main_questions,
      max_main_questions: state.limits.max_main_questions,
      aim_main_questions: state.limits.aim_main_questions,
      covered: state.covered,
      last_kind: state.last_kind
    }
  end

  defp handle_turn({:ok, response}, state) do
    state = %{state | tokens: state.tokens + response.usage.total_tokens}

    case ConversationPrompt.parse(response.data) do
      {:ok, turn} ->
        apply_turn(turn, %{state | turn_attempts: 0})

      :error when state.turn_attempts == 0 ->
        Logger.warning("assessment turn unusable, asking again")
        {:noreply, run_turn(%{state | turn_attempts: 1})}

      :error ->
        fail(state, :fatal)
    end
  end

  # A busy or briefly failing model, after LLM.complete's retries: give
  # the answer back so the person can send it again. Nothing else is lost.
  # Before any answer (the first question) there is nothing to keep, and the
  # link is not yet used, so the session stops as before.
  defp handle_turn({:error, class}, state) when class in [:rate_limited, :transient] do
    case Transcript.unanswer(state.transcript) do
      {:ok, answer, transcript} ->
        Logger.warning("assessment turn not sent: #{class}, answer returned")
        notify(state, {:answer_not_sent, %{question: state.question, answer: answer}})

        {:noreply, %{state | transcript: transcript, status: :awaiting_answer, turn_attempts: 0}}

      :error ->
        fail(state, class)
    end
  end

  defp handle_turn({:error, class}, state), do: fail(state, class)

  defp apply_turn(turn, state) do
    covered = MapSet.union(state.covered, MapSet.new(turn.covered))
    state = %{state | covered: covered}
    # One follow-up, then move on (rubric principle 4).
    kind = if state.last_kind == :follow_up, do: :main, else: turn.kind
    turns = Transcript.size(state.transcript)

    cond do
      state.tokens >= state.limits.max_tokens ->
        close(state, :max_tokens)

      closing?(turn, covered, state) ->
        close(state, :covered)

      kind == :main and state.main_questions >= state.limits.max_main_questions ->
        close(state, :max_questions)

      turns >= state.limits.max_turns ->
        close(state, :max_turns)

      true ->
        {:noreply, ask(state, turn.question, kind)}
    end
  end

  # The model may close when it judges every area covered. All areas
  # covered closes too, but not before the minimum number of main questions
  # while the model still has a question to ask.
  defp closing?(turn, covered, state) do
    turn.close or turn.question == "" or
      (MapSet.size(covered) == length(Rubric.areas()) and
         state.main_questions >= state.limits.min_main_questions)
  end

  defp ask(state, question, kind) do
    transcript = Transcript.ask(state.transcript, question, kind)
    main = if kind == :main, do: state.main_questions + 1, else: state.main_questions

    shown = %{
      text: question,
      number: Transcript.size(transcript),
      kind: kind,
      first?: Transcript.size(transcript) == 1,
      covered: MapSet.size(state.covered),
      done: progress_done(state.main_questions, MapSet.size(state.covered), state.limits),
      steps: progress_steps(state.limits)
    }

    notify(state, {:question, shown})

    %{
      state
      | transcript: transcript,
        question: shown,
        main_questions: main,
        last_kind: kind,
        status: :awaiting_answer
    }
  end

  @doc """
  The number of segments in the progress rule: one for each main question
  at the top of the aim (14 in a full session, 4 in a quick one).
  """
  @spec progress_steps(map()) :: pos_integer()
  def progress_steps(%{aim_main_questions: {_low, high}}), do: high

  @doc """
  How many segments of the progress rule are filled when a question is
  shown: one for each main question already answered, or the share of the
  areas covered if that is further on. The model is sparing about calling
  an area covered, so coverage alone barely moves the rule (#800). The
  last segment fills only when the conversation closes.
  """
  @spec progress_done(non_neg_integer(), non_neg_integer(), map()) :: non_neg_integer()
  def progress_done(main_answered, covered, limits) do
    steps = progress_steps(limits)
    by_areas = div(covered * steps, length(Rubric.areas()))
    max(main_answered, by_areas) |> min(steps - 1)
  end

  ## Closing and the report

  defp close(state, reason) do
    state = cancel_task(state)
    transcript = Transcript.answered(state.transcript)
    Logger.info("assessment closed: #{reason}, #{Transcript.size(transcript)} answers")

    if Transcript.size(transcript) == 0 do
      fail(state, :no_answers)
    else
      notify(state, {:closed, reason})
      {:noreply, write_report(%{state | transcript: transcript, question: nil})}
    end
  end

  # The reading list is read in the task, so a database failure is caught
  # like any other and reported to the owner.
  defp write_report(state) do
    %{role_group: group, client: client, reading: reading, transcript: transcript} = state

    %{state | status: :generating}
    |> start_task(fn -> Report.generate(group, transcript, reading(reading), client) end)
  end

  defp reading(fun) when is_function(fun, 0), do: fun.()
  defp reading(items) when is_list(items), do: items

  defp handle_report({:ok, report}, state) do
    notify(state, {:report, report})
    Process.send_after(self(), :expire, state.limits.report_ttl_ms)
    {:noreply, %{state | status: :done, report: report, transcript: %Transcript{}}}
  end

  # As for a turn: keep the answers, and let the person ask again, for as
  # long as a report would have been kept.
  defp handle_report({:error, class}, state) when class in [:rate_limited, :transient] do
    Logger.warning("assessment report not written: #{class}, waiting to try again")
    notify(state, {:report_not_written, class})
    timer = Process.send_after(self(), :give_up, state.limits.report_ttl_ms)
    {:noreply, %{state | status: :report_not_written, give_up_timer: timer}}
  end

  defp handle_report({:error, reason}, state), do: fail(state, reason)

  defp fail(state, reason) do
    Logger.warning("assessment failed: #{reason}")
    notify(state, {:failed, reason})
    {:stop, :normal, cancel_task(state)}
  end

  ## Tasks

  # Model calls run in a task so the session stays responsive (finish early,
  # the hard stop). Any exception, exit or throw is caught and reduced to an error class,
  # so no crash report from the task can carry the prompt.
  defp start_task(state, fun) do
    task =
      Task.Supervisor.async_nolink(@tasks, fn ->
        try do
          fun.()
        rescue
          e ->
            Logger.error("assessment model call raised #{inspect(e.__struct__)}")
            {:error, :fatal}
        catch
          kind, _reason ->
            Logger.error("assessment model call failed (#{kind})")
            {:error, :fatal}
        end
      end)

    %{state | task: task}
  end

  defp cancel_task(%{task: nil} = state), do: state

  defp cancel_task(%{task: task} = state) do
    Task.shutdown(task, :brutal_kill)
    %{state | task: nil}
  end

  # With no owner attached (it is reconnecting) the event is dropped;
  # `attach/2` reports where the session stands instead.
  defp notify(%{owner: nil}, _event), do: :ok
  defp notify(state, event), do: send(state.owner, {AiInPractice.Assessment, state.id, event})

  defp now, do: System.monotonic_time(:millisecond)

  ## Redaction

  defp redact_state(%__MODULE__{} = state) do
    %{
      state
      | transcript: :redacted,
        report: state.report && :redacted,
        reading: :redacted,
        question: state.question && :redacted
    }
  end

  defp redact_state(other), do: LogRedaction.scrub(other)

  defp redact_reason(reason), do: reason |> LogRedaction.strip_stacks() |> scrub_reason()

  # Keep an exception's type, not its message, which could quote data.
  defp scrub_reason({%{__exception__: true} = exception, stack}),
    do: {exception.__struct__, stack}

  defp scrub_reason({reason, stack}) when is_list(stack), do: {LogRedaction.scrub(reason), stack}
  defp scrub_reason(reason), do: LogRedaction.scrub(reason)
end
