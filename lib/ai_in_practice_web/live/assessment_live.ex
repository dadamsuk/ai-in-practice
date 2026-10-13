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

  **Voice** (v2, PRD §7 step 2–3, §10). When a transcriber is configured
  and answers (`AiInPractice.Transcriber.available?/0`, checked once the
  page connects), the start screen offers to begin with spoken answers.
  The question screen then has record and stop controls (the `.Voice`
  hook, MediaRecorder). Each recording is a LiveView upload kept in memory
  (`AiInPracticeWeb.MemoryUploadWriter`), sent to the transcriber from a
  task and dropped. The text is put in the answer box for the person to
  correct, and only what they send is an answer. Typing stays available
  throughout, and every failure says so. Questions are never spoken.

  **Reconnecting.** The session id is sent to the browser, which keeps it
  in a page variable (`.LiveSession` hook) and sends it back as the
  `attach` connect param if the socket reconnects. The session waits a
  short while for its owner to return (`:reattach_ms`), so a dropped
  connection carries on where it was. A reload or a closed tab starts a
  fresh page with no id: closing the page ends the conversation. A server
  restart cannot be recovered, and says so.
  """
  use AiInPracticeWeb, :live_view

  alias AiInPractice.{Assessment, Links, RoleGroups, Transcriber}
  alias AiInPractice.Assessment.Session
  alias AiInPractice.Reports.Content

  import AiInPracticeWeb.ReportComponents, only: [blocks: 1]

  @max_answer_chars 8_000

  # A recording stops by itself after five minutes (the hook), which at the
  # bitrate it asks for is well under a megabyte; the cap is generous for
  # browsers that ignore the bitrate.
  @max_recording_ms :timer.minutes(5)
  @max_audio_bytes 16_000_000

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
        max_answer_chars: @max_answer_chars,
        voice?: false,
        voice: :idle,
        voice_error: nil,
        max_recording_ms: @max_recording_ms
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
      {:ok, link} -> socket |> assign(phase: :start, link: link) |> check_voice()
      {:error, _} -> assign(socket, phase: :dead_end)
    end
  end

  # Whether to offer voice: asked once the page connects, so a slow or
  # absent transcriber never holds up the start screen.
  defp check_voice(socket) do
    if connected?(socket),
      do: start_async(socket, :voice_check, fn -> Transcriber.available?() end),
      else: socket
  end

  # A reconnect: carry on with the session if it is still there and belongs
  # to this link; otherwise the conversation was lost.
  defp reattach(socket, id) do
    with %{} = link <- Links.get_assessment_link_by_token(socket.assigns.token),
         {:ok, view} <- Assessment.attach(id, &(&1[:link_id] == link.id)) do
      socket
      |> assign(link: link, session_id: id, meta: view.meta, started?: link.status != :unused)
      |> allow_voice()
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
      begin(socket, link, group, mode(socket, params))
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
         assign(socket,
           phase: :thinking,
           answer: "",
           answer_error: nil,
           paste_note: false,
           voice: :idle,
           voice_error: nil
         )}

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

  # The draft, sent when the box loses focus, so that a re-render (the
  # voice controls change while the person works) puts back what they
  # wrote rather than an empty box.
  def handle_event("draft", %{"answer" => text}, %{assigns: %{phase: :question}} = socket)
      when is_binary(text),
      do: {:noreply, assign(socket, answer: String.slice(text, 0, @max_answer_chars))}

  def handle_event("paste_refused", _params, socket),
    do: {:noreply, assign(socket, paste_note: true)}

  # From the .Voice hook, which owns the microphone.
  def handle_event("recording", _params, %{assigns: %{phase: :question}} = socket),
    do: {:noreply, assign(socket, voice: :recording, voice_error: nil)}

  def handle_event("recorded", _params, %{assigns: %{voice: :recording}} = socket),
    do: {:noreply, assign(socket, voice: :transcribing)}

  def handle_event("recording_failed", params, socket) do
    error = if params["reason"] == "empty", do: :no_speech, else: :microphone
    {:noreply, voice_failed(socket, error)}
  end

  # The upload form: refuse anything the upload config rejects.
  def handle_event("voice_upload", _params, socket) do
    case socket.assigns[:uploads][:audio] do
      %{entries: entries} = upload ->
        if Enum.any?(entries, &(upload_errors(upload, &1) != [])) or upload_errors(upload) != [],
          do: {:noreply, socket |> cancel_audio() |> voice_failed(:unusable)},
          else: {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

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

  # Voice only if it was offered on this page.
  defp mode(%{assigns: %{voice?: true}}, %{"mode" => "voice"}), do: :voice
  defp mode(_socket, _params), do: :text

  defp begin(socket, link, group, mode) do
    meta = %{
      link_id: link.id,
      link_kind: link.kind,
      role_group: group,
      mode: mode,
      quick: link.quick,
      date: Date.utc_today()
    }

    case Assessment.start(group, meta: meta, quick: link.quick) do
      {:ok, id} ->
        {:noreply,
         socket
         |> assign(phase: :opening, link: link, session_id: id, meta: meta, role_error: nil)
         |> allow_voice()
         |> monitor_session(id)}

      {:error, _} ->
        {:noreply, failed(socket, :fatal)}
    end
  end

  defp hard_stop_minutes(meta) do
    meta
    |> Map.get(:quick, false)
    |> Assessment.limits()
    |> Map.fetch!(:hard_stop_ms)
    |> div(60_000)
  end

  defp allow_voice(%{assigns: %{meta: %{mode: :voice}}} = socket) do
    allow_upload(socket, :audio,
      accept: :any,
      max_entries: 1,
      max_file_size: @max_audio_bytes,
      auto_upload: true,
      progress: &audio_progress/3,
      writer: fn _name, _entry, _socket ->
        {AiInPracticeWeb.MemoryUploadWriter, max_bytes: @max_audio_bytes}
      end
    )
  end

  defp allow_voice(socket), do: socket

  defp cancel_audio(socket) do
    Enum.reduce(socket.assigns.uploads.audio.entries, socket, fn entry, socket ->
      cancel_upload(socket, :audio, entry.ref)
    end)
  end

  # The whole recording has arrived: take it out of the upload (it was
  # never on disk) and send it to the transcriber from a task. The answer
  # box is the person's; the text is pushed to the hook, which adds it.
  defp audio_progress(:audio, %{done?: true} = entry, %{assigns: %{phase: :question}} = socket) do
    audio = consume_uploaded_entry(socket, entry, fn %{audio: audio} -> {:ok, audio} end)

    case Transcriber.format(entry.client_type) do
      {:ok, format} ->
        {:noreply,
         socket
         |> assign(voice: :transcribing, voice_error: nil)
         |> start_async(:transcribe, fn -> Transcriber.transcribe(audio, format) end)}

      :error ->
        {:noreply, voice_failed(socket, :unusable)}
    end
  end

  defp audio_progress(:audio, %{done?: true} = entry, socket) do
    _ = consume_uploaded_entry(socket, entry, fn _meta -> {:ok, nil} end)
    {:noreply, socket}
  end

  defp audio_progress(:audio, _entry, socket), do: {:noreply, socket}

  defp voice_failed(socket, error), do: assign(socket, voice: :idle, voice_error: error)

  @impl true
  def handle_async(:voice_check, {:ok, available?}, socket),
    do: {:noreply, assign(socket, voice?: available? == true)}

  def handle_async(:voice_check, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, voice?: false)}

  def handle_async(:transcribe, result, %{assigns: %{phase: :question}} = socket) do
    case result do
      {:ok, {:ok, text}} ->
        {:noreply,
         socket
         |> assign(voice: :idle, voice_error: nil)
         |> push_event("transcribed", %{text: text})}

      {:ok, {:error, class}} ->
        {:noreply, voice_failed(socket, class)}

      {:exit, _reason} ->
        {:noreply, voice_failed(socket, :unavailable)}
    end
  end

  # The question moved on (time up, finished early) before the text came.
  def handle_async(:transcribe, _result, socket),
    do: {:noreply, assign(socket, voice: :idle, voice_error: nil)}

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
        assign(socket,
          phase: :question,
          question: question,
          answer: "",
          answer_error: nil,
          voice: :idle,
          voice_error: nil
        )

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
    <p :if={!@link.quick} class="lede">
      About 20 to 25 minutes of questions, answered in your own words. At the end you get two reports.
    </p>
    <p :if={@link.quick} class="lede" id="quick">
      A quick session, a trial run: three or four questions in about three minutes, answered in your own words. At the end you get two reports, marked as quick.
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
      <li :if={!@link.quick}>It takes about 20 to 25 minutes, and stops after 40 at most.</li>
      <li :if={@link.quick}>It takes about three minutes, and stops after eight at most.</li>
      <li>
        You have one attempt. Closing or reloading this page ends the conversation, and the link cannot be opened again.
      </li>
      <li>You may leave out the names of clients and employers, and give figures as ranges.</li>
      <li :if={!@voice?}>
        Type your answers. Pasting is turned off, but your computer's dictation works.
      </li>
      <li :if={@voice?} id="voice-offered">
        Type your answers, or speak them and correct the text before you send it. Pasting is turned off, but your computer's dictation works.
      </li>
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

    <%= if @voice? do %>
      <h2>Typing or speaking</h2>
      <p id="voice-handling">
        If you choose to speak, each recording goes to DSC's own transcription service, is turned into text and is deleted at once. It is never stored. You see the text and can correct it before you send it, and you can type instead at any point. The questions are only ever shown on screen. Your reports say whether your answers were typed or spoken, and transcription slips never count against you.
      </p>
    <% end %>

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
      <%= if @voice? do %>
        <div class="page-actions">
          <.button variant="primary" id="begin" name="mode" value="text">
            Begin, typing my answers
          </.button>
          <.button id="begin-voice" name="mode" value="voice">
            Begin, speaking my answers
          </.button>
        </div>
      <% else %>
        <.button variant="primary" id="begin">Begin the conversation</.button>
      <% end %>
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
      <.voice
        :if={@meta && @meta.mode == :voice && @uploads[:audio]}
        uploads={@uploads}
        voice={@voice}
        voice_error={@voice_error}
        max_recording_ms={@max_recording_ms}
      />
      <.form for={%{}} id="answer-form" phx-submit="answer" phx-change="draft">
        <div class="field">
          <label for={"answer-#{@question.number}"} class="field-label">your answer</label>
          <textarea
            id={"answer-#{@question.number}"}
            name="answer"
            rows="8"
            maxlength={@max_answer_chars}
            phx-hook=".AnswerBox"
            phx-debounce="blur"
            aria-describedby="answer-help"
            aria-invalid={@answer_error && "true"}
          >{@answer}</textarea>
          <p :if={@answer_error} class="field-error" id="answer-error" role="alert">
            {@answer_error}
          </p>
          <p id="answer-help" class="quiet">
            <span :if={!@paste_note && @meta.mode == :voice}>
              Record, or type. Check the text and correct anything misheard before you send it.
            </span>
            <span :if={!@paste_note && @meta.mode != :voice}>
              Type, or use your computer's dictation.
            </span>
            <span :if={@paste_note} id="paste-note" role="status">
              Pasting is turned off here. Please type your answer, or use your computer's dictation.
            </span>
          </p>
        </div>
        <.button variant="primary" id="send" disabled={@voice == :transcribing}>
          Send answer
        </.button>
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
      The {hard_stop_minutes(@meta)} minutes are up, so the conversation has closed.
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
      The {hard_stop_minutes(@meta)} minutes were up, so the conversation closed there.
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

  attr :uploads, :map, required: true
  attr :voice, :atom, required: true
  attr :voice_error, :atom, default: nil
  attr :max_recording_ms, :integer, required: true

  # Record and stop, for spoken answers. The .Voice hook owns the
  # microphone: it tells the server when recording starts and stops, then
  # uploads the recording into the hidden input; the text comes back as a
  # "transcribed" event and goes into the answer box.
  defp voice(assigns) do
    ~H"""
    <section
      id="voice"
      class="voice"
      phx-hook=".Voice"
      data-state={@voice}
      data-max-ms={@max_recording_ms}
      aria-label="speak your answer"
    >
      <form id="voice-form" phx-change="voice_upload" phx-submit="voice_upload" hidden>
        <.live_file_input upload={@uploads.audio} />
      </form>
      <%= case @voice do %>
        <% :recording -> %>
          <p class="recording" id="recording" role="status">
            Recording. Speak your answer, then stop.
          </p>
          <.button type="button" id="stop-recording" data-voice="stop">Stop recording</.button>
          <p class="quiet">It stops by itself after five minutes.</p>
        <% :transcribing -> %>
          <p class="lede" id="transcribing" role="status">Turning your recording into text.</p>
        <% :idle -> %>
          <.button type="button" id="record" data-voice="start">Record your answer</.button>
      <% end %>
      <p :if={@voice_error} class="field-error" id="voice-error" role="alert">
        {voice_message(@voice_error)}
      </p>
    </section>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Voice">
      // Records one answer at a time with MediaRecorder and uploads it.
      // Nothing is kept here: the recording is dropped once it is sent,
      // and the microphone is released whenever recording stops.
      const TYPES = ["audio/webm;codecs=opus", "audio/ogg;codecs=opus", "audio/mp4", "audio/webm"]

      export default {
        mounted() {
          this.onClick = (e) => {
            const action = e.target.closest("[data-voice]")?.dataset.voice
            if (action === "start") this.start()
            if (action === "stop") this.stop()
          }
          this.el.addEventListener("click", this.onClick)
          this.handleEvent("transcribed", ({text}) => this.insert(text))
        },
        destroyed() {
          this.el.removeEventListener("click", this.onClick)
          this.release(true)
        },
        async start() {
          if (this.recorder) return
          if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) {
            return this.pushEvent("recording_failed", {reason: "unsupported"})
          }
          try {
            this.stream = await navigator.mediaDevices.getUserMedia({audio: true})
          } catch (_e) {
            return this.pushEvent("recording_failed", {reason: "denied"})
          }
          const mimeType = TYPES.find((t) => MediaRecorder.isTypeSupported(t))
          const options = {audioBitsPerSecond: 32000, ...(mimeType ? {mimeType} : {})}
          const chunks = []
          this.recorder = new MediaRecorder(this.stream, options)
          this.recorder.ondataavailable = (e) => { if (e.data.size > 0) chunks.push(e.data) }
          this.recorder.onstop = () => {
            const type = (this.recorder?.mimeType || mimeType || "audio/webm")
            this.release(false)
            if (this.discard) return
            const blob = new Blob(chunks, {type})
            chunks.length = 0
            if (blob.size === 0) return this.pushEvent("recording_failed", {reason: "empty"})
            this.pushEvent("recorded", {})
            this.upload("audio", [new File([blob], "answer", {type})])
          }
          this.discard = false
          this.recorder.start()
          this.timer = setTimeout(() => this.stop(), Number(this.el.dataset.maxMs))
          this.pushEvent("recording", {})
        },
        stop() {
          if (this.recorder && this.recorder.state !== "inactive") this.recorder.stop()
        },
        release(discard) {
          clearTimeout(this.timer)
          if (discard) {
            this.discard = true
            this.stop()
          }
          this.stream?.getTracks().forEach((t) => t.stop())
          this.stream = null
          this.recorder = null
        },
        // The text goes after anything already written, for the person to
        // correct; it is theirs once it is in the box.
        insert(text) {
          const box = document.querySelector("#answer-form textarea")
          if (!box) return
          const before = box.value.replace(/\s+$/, "")
          box.value = before ? `${before} ${text}` : text
          box.focus()
          box.setSelectionRange(box.value.length, box.value.length)
          // As if typed, so the draft reaches the server when the box
          // loses focus.
          box.dispatchEvent(new Event("input", {bubbles: true}))
        }
      }
    </script>
    """
  end

  defp voice_message(:microphone),
    do:
      "The microphone could not be used. Allow this page to use it and record again, or type your answer."

  defp voice_message(:no_speech),
    do: "No words were heard in that recording. Record again, or type your answer."

  defp voice_message(:unusable),
    do: "That recording could not be used. Record again, or type your answer."

  defp voice_message(:unavailable),
    do:
      "Your recording could not be turned into text just now. Record again in a moment, or type your answer."

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
