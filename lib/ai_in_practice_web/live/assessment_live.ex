defmodule AiInPracticeWeb.AssessmentLive do
  @moduledoc """
  The candidate journey (PRD §7): the start screen, the conversation, the
  generating screen and the reports, with every error and unavailable
  state, at `/a/:token`. `AiInPracticeWeb.Plugs.UsableLink` lets only a
  link that can be started this far; anything else gets the dead end.

  This process owns the assessment session (`AiInPractice.Assessment`), so
  the conversation and the reports live only in its memory and the
  session's (PRD §10).

  **The link** is used up when the first question arrives
  (`Links.mark_started/2`) and completed when the reports arrive. A failure
  before the first question leaves it unused (PRD §6).

  **Closing the page** ends the session at once: on `pagehide` the
  `.LiveSession` hook sends a beacon to `AiInPracticeWeb.SessionController`.
  The reconnect grace period covers a page that goes without one.

  **Reconnecting.** The session id is sent to the browser, which keeps it
  in a page variable (`.LiveSession` hook) and sends it back as the
  `attach` connect param if the socket reconnects. The session waits a
  short while for its owner to return (`:reattach_ms`), so a dropped
  connection carries on where it was. A reload or a closed tab starts a
  fresh page with no id: closing the page ends the conversation. A server
  restart cannot be recovered, and says so.
  """
  use AiInPracticeWeb, :live_view

  alias AiInPractice.{Assessment, Links, RoleGroups}
  alias AiInPractice.Assessment.Session
  alias AiInPractice.Reports.Content

  import AiInPracticeWeb.ReportComponents, only: [blocks: 1]

  @max_answer_chars 8_000

  @impl true
  def mount(params, session, socket) do
    token = token(params, session)

    socket =
      assign(socket,
        page_title: "AI in Practice",
        token: token,
        link: nil,
        session_id: nil,
        session_ref: nil,
        started?: false,
        question: nil,
        answer: "",
        answer_error: nil,
        paste_note: false,
        closed: nil,
        report: nil,
        meta: nil,
        reason: nil,
        role_form: to_form(%{"role_group" => ""}),
        role_error: nil,
        max_answer_chars: @max_answer_chars
      )

    attach = connected?(socket) && get_connect_params(socket)["attach"]

    if is_binary(attach) and attach != "" do
      {:ok, reattach(socket, attach)}
    else
      {:ok, fresh(socket)}
    end
  end

  # From the path; tests that reconnect mount with `live_isolated` and a
  # "token" in the session, since a reconnect makes no HTTP request.
  defp token(%{"token" => token}, _session), do: token
  defp token(_params, %{"token" => token}), do: token

  defp fresh(socket) do
    case Links.begin_session(socket.assigns.token) do
      {:ok, link} -> assign(socket, phase: :start, link: link)
      {:error, _} -> assign(socket, phase: :dead_end)
    end
  end

  # A reconnect: carry on with the session if it is still there and belongs
  # to this link; otherwise the conversation was lost.
  defp reattach(socket, id) do
    with %{} = link <- Links.get_assessment_link_by_token(socket.assigns.token),
         {:ok, view} <- Assessment.attach(id, &(&1[:link_id] == link.id)) do
      socket
      |> assign(link: link, session_id: id, meta: view.meta, started?: link.status != :unused)
      |> monitor_session(id)
      |> resume(view)
    else
      _ -> lost(socket)
    end
  end

  defp resume(socket, %{status: :done, report: report}), do: show_reports(socket, report)
  defp resume(socket, %{status: :generating}), do: assign(socket, phase: :generating)

  defp resume(socket, %{status: :awaiting_answer, question: question}),
    do: assign(socket, phase: :question, question: question)

  defp resume(socket, %{question: nil}), do: assign(socket, phase: :opening)

  defp resume(socket, %{question: question}),
    do: assign(socket, phase: :thinking, question: question)

  defp lost(socket) do
    case Links.get_assessment_link_by_token(socket.assigns.token) do
      %{status: :unused} -> fresh(socket)
      nil -> assign(socket, phase: :dead_end)
      link -> assign(socket, phase: :failed, reason: :lost, link: link, started?: true)
    end
  end

  ## Events

  @impl true
  def handle_event("begin", params, %{assigns: %{phase: :start}} = socket) do
    with {:ok, link} <- Links.begin_session(socket.assigns.token),
         {:ok, group} <- role_group(link, params) do
      begin(socket, link, group)
    else
      :choose_role ->
        {:noreply, assign(socket, role_error: "Choose the role group closest to yours.")}

      {:error, _} ->
        {:noreply, assign(socket, phase: :dead_end)}
    end
  end

  def handle_event("answer", %{"answer" => text}, %{assigns: %{phase: :question}} = socket)
      when is_binary(text) do
    case Assessment.answer(socket.assigns.session_id, text) do
      :ok ->
        {:noreply,
         assign(socket, phase: :thinking, answer: "", answer_error: nil, paste_note: false)}

      {:error, :empty} ->
        {:noreply,
         assign(socket, answer: text, answer_error: "Write an answer before sending it.")}

      {:error, :too_long} ->
        {:noreply,
         assign(socket,
           answer: text,
           answer_error:
             "That answer is longer than #{format_number(@max_answer_chars)} characters. Please shorten it."
         )}

      {:error, :not_waiting} ->
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, failed(socket, :fatal)}
    end
  end

  def handle_event("paste_refused", _params, socket),
    do: {:noreply, assign(socket, paste_note: true)}

  def handle_event("finish", _params, %{assigns: %{phase: phase}} = socket)
      when phase in [:question, :thinking] do
    case Assessment.finish_early(socket.assigns.session_id) do
      :ok -> {:noreply, assign(socket, phase: :generating, closed: :finished_early)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp role_group(%{kind: :individual}, %{"role_group" => value}) do
    case RoleGroups.parse(value) do
      {:ok, group} -> {:ok, group}
      :error -> :choose_role
    end
  end

  defp role_group(%{kind: :individual}, _params), do: :choose_role
  defp role_group(%{role_group: group}, _params), do: {:ok, group}

  defp begin(socket, link, group) do
    meta = %{
      link_id: link.id,
      link_kind: link.kind,
      role_group: group,
      mode: :text,
      date: Date.utc_today()
    }

    case Assessment.start(group, meta: meta) do
      {:ok, id} ->
        {:noreply,
         socket
         |> assign(phase: :opening, link: link, session_id: id, meta: meta, role_error: nil)
         |> monitor_session(id)}

      {:error, _} ->
        {:noreply, failed(socket, :fatal)}
    end
  end

  defp monitor_session(socket, id) do
    case Session.whereis(id) do
      nil -> socket
      pid -> assign(socket, session_ref: Process.monitor(pid))
    end
  end

  ## Session events

  @impl true
  def handle_info({Assessment, id, event}, %{assigns: %{session_id: id}} = socket),
    do: {:noreply, on_event(event, socket)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{assigns: %{session_ref: ref}} = socket) do
    # The session stopped. After a failure or expiry the screen already
    # says why; anything else is unexpected.
    socket = assign(socket, session_ref: nil)

    if ended_phase?(socket.assigns.phase),
      do: {:noreply, socket},
      else: {:noreply, failed(socket, :fatal)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp on_event({:question, question}, socket) do
    case start_link(socket, question) do
      {:ok, socket} ->
        assign(socket, phase: :question, question: question, answer: "", answer_error: nil)

      :lost_race ->
        Assessment.stop(socket.assigns.session_id)
        assign(socket, phase: :dead_end, session_id: nil, question: nil)
    end
  end

  defp on_event({:closed, reason}, socket),
    do: assign(socket, phase: :generating, closed: reason, question: nil)

  defp on_event({:report, report}, socket) do
    _ = Links.mark_completed(socket.assigns.link)
    show_reports(socket, report)
  end

  defp on_event({:failed, reason}, socket), do: failed(socket, reason)

  defp on_event(:expired, socket),
    do: assign(socket, phase: :expired, report: nil, candidate: nil, assessor: nil)

  # The first question is on its way to the screen: use the link up now
  # (PRD §6). If another tab started it first, this one stops.
  defp start_link(%{assigns: %{started?: true}} = socket, _question), do: {:ok, socket}

  defp start_link(socket, %{first?: true}) do
    %{link: link, meta: meta} = socket.assigns

    case Links.mark_started(link, %{role_group: meta.role_group, mode: meta.mode}) do
      {:ok, link} -> {:ok, assign(socket, link: link, started?: true)}
      {:error, _} -> :lost_race
    end
  end

  defp start_link(socket, _question), do: {:ok, socket}

  defp show_reports(socket, report) do
    assign(socket,
      phase: :reports,
      report: report,
      candidate: Content.candidate(report),
      assessor: Content.assessor(report),
      question: nil
    )
  end

  defp failed(socket, reason) do
    if id = socket.assigns.session_id, do: Assessment.stop(id)
    assign(socket, phase: :failed, reason: reason, question: nil, report: nil)
  end

  # Enum.member?/2 rather than `in`, which :cover cannot compile here.
  defp live_phase?(phase),
    do: Enum.member?([:opening, :question, :thinking, :generating, :reports], phase)

  defp ended_phase?(phase), do: Enum.member?([:failed, :expired, :dead_end], phase)

  defp format_number(n),
    do: n |> Integer.to_string() |> String.replace(~r/(\d)(?=(\d{3})+$)/, "\\1,")

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        :if={live_phase?(@phase)}
        id="live-session"
        phx-hook=".LiveSession"
        data-session={@session_id}
        hidden
      >
      </div>
      <div
        :if={ended_phase?(@phase)}
        id="session-ended"
        phx-hook=".SessionEnded"
        hidden
      >
      </div>
      {phase(assigns)}
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".LiveSession">
      // While a conversation or its reports are on screen: keep the session
      // id in this page only (so a reconnect can carry on), and warn before
      // the page is closed, since nothing is kept.
      // When the page really goes, say so, so the session ends at once
      // rather than waiting out the reconnect grace period.
      export default {
        mounted() {
          this.warn = (e) => { e.preventDefault(); e.returnValue = "" }
          // A beacon, because the socket is already closing by now.
          this.leave = () => {
            const id = this.el.dataset.session
            if (id) navigator.sendBeacon(`/sessions/${id}/end`)
          }
          window.addEventListener("beforeunload", this.warn)
          window.addEventListener("pagehide", this.leave)
          this.updated()
        },
        updated() {
          if (this.el.dataset.session) window.aipAttach = this.el.dataset.session
        },
        destroyed() {
          window.removeEventListener("beforeunload", this.warn)
          window.removeEventListener("pagehide", this.leave)
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SessionEnded">
      export default {
        mounted() { window.aipAttach = null }
      }
    </script>
    """
  end

  defp phase(%{phase: :start} = assigns) do
    ~H"""
    <h1>A conversation about how you work with AI</h1>
    <p class="lede">
      About 20 to 25 minutes of questions, answered in your own words. At the end you get two reports.
    </p>

    <p :if={@link.kind == :candidate} id="sender">
      <strong>{@link.recruiter_link.firm_name}</strong>
      sent you this link. They can see whether you have started and completed it. They see nothing you write unless you send them the assessor report yourself.
    </p>

    <h2>What this is</h2>
    <p>
      A conversation starter. It makes no decision about you, and there are no scores. You get a private report with next steps, and an assessor report that you can read first and then choose whether to send on.
    </p>

    <h2>Before you begin</h2>
    <ul id="before-you-begin">
      <li>It takes about 20 to 25 minutes, and stops after 40 at most.</li>
      <li>
        You have one attempt. Closing or reloading this page ends the conversation, and the link cannot be opened again.
      </li>
      <li>You may leave out the names of clients and employers, and give figures as ranges.</li>
      <li>Type your answers. Pasting is turned off, but your computer's dictation works.</li>
      <li>You can finish early at any point.</li>
    </ul>

    <h2>How your answers are handled</h2>
    <p id="data-handling">
      Your answers and reports are held in this server's memory only while this page is open. They are never written to disk, to a database or to a log. On the way they pass through Cloudflare, which secures the connection to this site. To write the questions and the reports, your answers are sent through OpenRouter to the AI model's provider, with zero data retention. When you close this page, they are gone.
    </p>
    <p id="legal">
      The <.link href={~p"/privacy"} target="_blank" rel="noopener">privacy notice</.link>
      sets out exactly what is kept and what is not, and the
      <.link href={~p"/terms"} target="_blank" rel="noopener">terms</.link>
      explain why this is never an automated decision about you. Both open in a new tab.
    </p>

    <.form for={@role_form} id="begin-form" phx-submit="begin">
      <%= if @link.kind == :individual do %>
        <.input
          field={@role_form[:role_group]}
          type="select"
          label="your role group"
          prompt="Choose the one closest to yours"
          options={RoleGroups.options()}
          aria-describedby={@role_error && "role-error"}
        />
        <p :if={@role_error} class="field-error" id="role-error" role="alert">{@role_error}</p>
      <% else %>
        <.list>
          <:item title="role group">
            <span id="role-group">{RoleGroups.name(@link.role_group)}</span>
          </:item>
        </.list>
      <% end %>
      <.button variant="primary" id="begin">Begin the conversation</.button>
    </.form>
    <p class="quiet">Your link is used once the first question appears.</p>
    """
  end

  defp phase(%{phase: :opening} = assigns) do
    ~H"""
    <.progress covered={0} />
    <p class="lede" role="status" id="status">Your first question is being written.</p>
    """
  end

  defp phase(%{phase: phase} = assigns) when phase in [:question, :thinking] do
    ~H"""
    <.progress covered={@question.covered} />
    <h1
      id="question"
      class="question"
      tabindex="-1"
      phx-hook=".Question"
      data-number={@question.number}
    >
      {@question.text}
    </h1>

    <%= if @phase == :question do %>
      <.form for={%{}} id="answer-form" phx-submit="answer">
        <div class="field">
          <label for={"answer-#{@question.number}"} class="field-label">your answer</label>
          <textarea
            id={"answer-#{@question.number}"}
            name="answer"
            rows="8"
            maxlength={@max_answer_chars}
            phx-hook=".AnswerBox"
            aria-describedby="answer-help"
            aria-invalid={@answer_error && "true"}
          >{@answer}</textarea>
          <p :if={@answer_error} class="field-error" id="answer-error" role="alert">
            {@answer_error}
          </p>
          <p id="answer-help" class="quiet">
            <span :if={!@paste_note}>Type, or use your computer's dictation.</span>
            <span :if={@paste_note} id="paste-note" role="status">
              Pasting is turned off here. Please type your answer, or use your computer's dictation.
            </span>
          </p>
        </div>
        <.button variant="primary" id="send">Send answer</.button>
      </.form>
    <% else %>
      <p class="quiet" role="status" id="status">The next question is being written.</p>
    <% end %>

    <hr />
    <.button
      type="button"
      id="finish"
      phx-click="finish"
      data-confirm="Finish now? Your reports will be written from what you have said so far."
    >
      Finish early
    </.button>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Question">
      // Move focus to each new question, so it is read out and the person
      // carries on from there.
      export default {
        mounted() { this.el.focus() },
        updated() { this.el.focus() }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AnswerBox">
      // Paste and drop are refused (PRD §7); typing and dictation are not.
      export default {
        mounted() {
          const refuse = (e) => { e.preventDefault(); this.pushEvent("paste_refused", {}) }
          this.el.addEventListener("paste", refuse)
          this.el.addEventListener("drop", refuse)
        }
      }
    </script>
    """
  end

  defp phase(%{phase: :generating} = assigns) do
    ~H"""
    <h1>Writing your reports</h1>
    <p :if={@closed == :time_limit} id="time-up">
      The 40 minutes are up, so the conversation has closed.
    </p>
    <p class="lede" role="status" id="status">
      This usually takes under a minute. Please keep this page open.
    </p>
    """
  end

  defp phase(%{phase: :reports} = assigns) do
    ~H"""
    <h1>Your reports</h1>
    <p :if={@closed == :time_limit} id="time-up" class="quiet">
      The 40 minutes were up, so the conversation closed there.
    </p>

    <section class="notice" id="nothing-kept" role="note">
      <h2>Nothing is kept</h2>
      <p>
        <strong>When you close this page, both reports are gone for good.</strong>
        Download them first. They stay available here for an hour at most.
      </p>
    </section>

    <.downloads session_id={@session_id} kind={@link.kind} primary />

    <section id="candidate-report" class="report">
      <h2 class="report-title">{Content.title(:candidate)}</h2>
      <p class="quiet">Private to you. Read it, keep it, share it if you wish.</p>
      <.report_header meta={@meta} />
      <.blocks blocks={@candidate} />
    </section>

    <section id="assessor-report" class="report">
      <h2 class="report-title">{Content.title(:assessor)}</h2>
      <p class="quiet">
        {if @link.kind == :candidate,
          do:
            "Read it before you decide whether to send it to the recruiter. You send it yourself: DSC never does.",
          else: "Read it before you decide whether to share it with anyone."}
      </p>
      <.report_header meta={@meta} />
      <.blocks blocks={@assessor} />
    </section>

    <.downloads session_id={@session_id} kind={@link.kind} id="downloads-end" />
    """
  end

  defp phase(%{phase: :failed} = assigns) do
    ~H"""
    <div id="failed" data-reason={@reason}>
      <%= cond do %>
        <% not @started? and @reason == :spend_refused -> %>
          <h1>The conversation is not available just now</h1>
          <p class="lede">This is a temporary problem on our side.</p>
          <p>Your link has not been used. Please come back to it later today or tomorrow.</p>
        <% not @started? -> %>
          <h1>The conversation could not begin</h1>
          <p class="lede">Something went wrong on our side before the first question.</p>
          <p>
            Your link has not been used. <.link href={~p"/a/#{@token}"}>Try again</.link>
            in a few minutes.
          </p>
        <% @reason == :report_invalid -> %>
          <h1>Sorry, your reports could not be written</h1>
          <p class="lede">
            The conversation finished, but the reports did not come out properly, so none are shown.
          </p>
          <.replacement link={@link} />
        <% @reason == :no_answers -> %>
          <h1>The conversation ended before any answers</h1>
          <p class="lede">There is nothing to write a report from.</p>
          <.replacement link={@link} />
        <% @reason == :lost -> %>
          <h1>The conversation was interrupted</h1>
          <p class="lede">
            The connection to the server was lost, and the conversation cannot be picked up again.
          </p>
          <.replacement link={@link} />
        <% true -> %>
          <h1>Sorry, the conversation has stopped</h1>
          <p class="lede">Something went wrong on our side and it could not carry on.</p>
          <.replacement link={@link} />
      <% end %>
    </div>
    """
  end

  defp phase(%{phase: :expired} = assigns) do
    ~H"""
    <h1>Your reports are no longer available</h1>
    <p class="lede">Reports are held for an hour at most, and then discarded.</p>
    <.replacement link={@link} />
    """
  end

  defp phase(%{phase: :dead_end} = assigns) do
    ~H"""
    <AiInPracticeWeb.AssessmentHTML.dead_end />
    """
  end

  ## Components

  attr :covered, :integer, required: true

  # A quiet rule of five segments, filled as the conversation moves on.
  defp progress(assigns) do
    ~H"""
    <div
      class="progress"
      id="progress"
      role="progressbar"
      aria-label="progress through the conversation"
      aria-valuemin="0"
      aria-valuemax="5"
      aria-valuenow={@covered}
    >
      <span :for={i <- 1..5} class={["progress-step", i <= @covered && "progress-done"]}></span>
    </div>
    """
  end

  attr :link, :any, required: true

  defp replacement(assigns) do
    ~H"""
    <p id="replacement">
      Nothing you said has been kept. This link cannot be opened again, but
      <%= if @link && @link.kind == :candidate do %>
        {@link.recruiter_link.firm_name}, who sent it, can send you a new one. Let them know what happened.
      <% else %>
        David at DSC, who sent it, can send you a new one. Let David know what happened.
      <% end %>
    </p>
    """
  end

  attr :session_id, :string, required: true
  attr :kind, :atom, required: true
  attr :primary, :boolean, default: false
  attr :id, :string, default: "downloads"

  defp downloads(assigns) do
    ~H"""
    <div class="page-actions" id={@id}>
      <.button
        href={~p"/reports/#{@session_id}/candidate"}
        variant={@primary && "primary"}
        download
      >
        Download your report (PDF)
      </.button>
      <.button
        href={~p"/reports/#{@session_id}/assessor"}
        variant={@primary && "primary"}
        download
      >
        Download the assessor report (PDF)
      </.button>
    </div>
    """
  end

  attr :meta, :map, required: true

  defp report_header(assigns) do
    ~H"""
    <.list>
      <:item :for={{label, value} <- Content.header(@meta)} title={label}>
        <span class="mono">{value}</span>
      </:item>
    </.list>
    """
  end
end
