defmodule AiInPractice.Links do
  @moduledoc """
  Links and access (PRD §6): the only persistent data in the app.

  David issues recruiter-mode and individual-mode links. A recruiter mints
  single-use candidate links up to their quota. An assessment link is used
  up when the session starts, meaning the moment the first question has
  been shown (`mark_started/2`). A start that fails before then leaves it
  unused.

  **Quota.** A candidate link counts against its recruiter's quota while it
  is unused (and not withdrawn) and once it is completed. A link that was
  started and never completed does not count, so the recruiter can mint a
  replacement.

  **Abandoned.** A link started more than `abandoned_after/0` seconds ago
  and not completed. This is past the 40-minute hard stop, so it can no
  longer finish. It matters only for the admin usage table: a started link
  can never be reopened, whatever its age.

  Tokens are returned once, when a link is created, and only their hash is
  stored (`AiInPractice.Links.Token`).
  """

  import Ecto.Query

  alias AiInPractice.Links.{AssessmentLink, RecruiterLink, Token}
  alias AiInPractice.Repo
  alias AiInPractice.RoleGroups

  @abandoned_after 60 * 60

  @type state :: :unused | :started | :completed | :abandoned | :revoked

  @doc "Seconds after starting at which an uncompleted link counts as abandoned."
  def abandoned_after, do: @abandoned_after

  ## Recruiter links

  @doc "A changeset for the admin form that issues a recruiter link."
  def change_recruiter_link(attrs \\ %{}),
    do: RecruiterLink.changeset(%RecruiterLink{}, attrs)

  @doc "Issues a recruiter-mode link. Returns the token, shown only this once."
  @spec create_recruiter_link(map()) ::
          {:ok, RecruiterLink.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_recruiter_link(attrs) do
    token = Token.generate()

    %RecruiterLink{}
    |> RecruiterLink.changeset(attrs)
    |> RecruiterLink.put_token_hash(Token.hash(token))
    |> Repo.insert()
    |> with_token(token)
  end

  @doc "The recruiter link for a token, revoked or not; nil if there is none."
  @spec get_recruiter_link_by_token(term()) :: RecruiterLink.t() | nil
  def get_recruiter_link_by_token(token) when is_binary(token),
    do: Repo.get_by(RecruiterLink, token_hash: Token.hash(token))

  def get_recruiter_link_by_token(_), do: nil

  @doc "The recruiter link with this id, or nil."
  def get_recruiter_link(id), do: Repo.get(RecruiterLink, id)

  @doc "Every recruiter link, newest first."
  def list_recruiter_links do
    Repo.all(from r in RecruiterLink, order_by: [desc: r.inserted_at, desc: r.id])
  end

  @doc "Changes a recruiter's quota."
  @spec set_quota(RecruiterLink.t(), term()) ::
          {:ok, RecruiterLink.t()} | {:error, Ecto.Changeset.t()}
  def set_quota(%RecruiterLink{} = link, quota) do
    link
    |> RecruiterLink.quota_changeset(%{quota: quota})
    |> Repo.update()
  end

  @doc """
  Revokes a recruiter link. Its page then shows a dead end, and none of its
  unused candidate links can be started.
  """
  @spec revoke_recruiter_link(RecruiterLink.t()) ::
          {:ok, RecruiterLink.t()} | {:error, :already_revoked}
  def revoke_recruiter_link(%RecruiterLink{revoked_at: nil} = link) do
    link |> Ecto.Changeset.change(revoked_at: now()) |> Repo.update()
  end

  def revoke_recruiter_link(%RecruiterLink{}), do: {:error, :already_revoked}

  ## Candidate links

  @doc """
  Mints a candidate link for a recruiter, with the role group the recruiter
  chose. Refused when the recruiter link is revoked or its quota is used.
  The quota check and the insert run in one immediate transaction, so two
  mints at once cannot both take the last slot.
  """
  @spec mint_candidate_link(RecruiterLink.t(), term()) ::
          {:ok, AssessmentLink.t(), String.t()}
          | {:error, :revoked | :quota_reached | Ecto.Changeset.t()}
  def mint_candidate_link(%RecruiterLink{id: id}, role_group) do
    token = Token.generate()

    Repo.transaction(
      fn ->
        recruiter = Repo.get!(RecruiterLink, id)

        cond do
          recruiter.revoked_at -> Repo.rollback(:revoked)
          quota_used(recruiter) >= recruiter.quota -> Repo.rollback(:quota_reached)
          true -> insert_candidate(recruiter, role_group, token)
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, link} -> {:ok, link, token}
      error -> error
    end
  end

  defp insert_candidate(recruiter, role_group, token) do
    %AssessmentLink{}
    |> AssessmentLink.candidate_changeset(%{
      recruiter_link_id: recruiter.id,
      role_group: role_group
    })
    |> AssessmentLink.put_token_hash(Token.hash(token))
    |> Repo.insert()
    |> case do
      {:ok, link} -> link
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc "A changeset for the recruiter page's mint form."
  def change_candidate_link(attrs \\ %{}),
    do: AssessmentLink.candidate_changeset(%AssessmentLink{}, attrs)

  @doc "How much of a recruiter's quota is in use: unused (not withdrawn) plus completed."
  @spec quota_used(RecruiterLink.t()) :: non_neg_integer()
  def quota_used(%RecruiterLink{id: id}) do
    Repo.one(
      from l in AssessmentLink,
        where: l.recruiter_link_id == ^id,
        where: (l.status == :unused and is_nil(l.revoked_at)) or l.status == :completed,
        select: count()
    )
  end

  @doc "How many more candidate links a recruiter can mint."
  @spec quota_remaining(RecruiterLink.t()) :: non_neg_integer()
  def quota_remaining(%RecruiterLink{} = link), do: max(link.quota - quota_used(link), 0)

  @doc "A recruiter's candidate links, newest first."
  def list_candidate_links(%RecruiterLink{id: id}) do
    Repo.all(
      from l in AssessmentLink,
        where: l.recruiter_link_id == ^id,
        order_by: [desc: l.inserted_at, desc: l.id]
    )
  end

  @doc """
  Withdraws one of a recruiter's own unused candidate links, for instance
  one whose URL they have lost. It frees the quota slot.
  """
  @spec withdraw_candidate_link(RecruiterLink.t(), term()) ::
          {:ok, AssessmentLink.t()} | {:error, :not_found | :not_unused}
  def withdraw_candidate_link(%RecruiterLink{id: recruiter_id}, link_id) do
    case Repo.get_by(AssessmentLink, id: link_id, recruiter_link_id: recruiter_id) do
      nil ->
        {:error, :not_found}

      %AssessmentLink{status: :unused, revoked_at: nil} = link ->
        link |> Ecto.Changeset.change(revoked_at: now()) |> Repo.update()

      _ ->
        {:error, :not_unused}
    end
  end

  ## Individual links

  @doc "A changeset for the admin form that issues an individual link."
  def change_individual_link(attrs \\ %{}),
    do: AssessmentLink.individual_changeset(%AssessmentLink{}, attrs)

  @doc "Issues an individual-mode link with David's label. Returns the token, shown only this once."
  @spec create_individual_link(map()) ::
          {:ok, AssessmentLink.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_individual_link(attrs) do
    token = Token.generate()

    %AssessmentLink{}
    |> AssessmentLink.individual_changeset(attrs)
    |> AssessmentLink.put_token_hash(Token.hash(token))
    |> Repo.insert()
    |> with_token(token)
  end

  @doc "Every individual link, newest first."
  def list_individual_links do
    Repo.all(
      from l in AssessmentLink,
        where: l.kind == :individual,
        order_by: [desc: l.inserted_at, desc: l.id]
    )
  end

  ## Any assessment link

  @doc "The assessment link with this id, or nil."
  def get_assessment_link(id), do: Repo.get(AssessmentLink, id)

  @doc "Revokes an assessment link, so it can no longer be started."
  @spec revoke_assessment_link(AssessmentLink.t()) ::
          {:ok, AssessmentLink.t()} | {:error, :already_revoked}
  def revoke_assessment_link(%AssessmentLink{revoked_at: nil} = link) do
    link |> Ecto.Changeset.change(revoked_at: now()) |> Repo.update()
  end

  def revoke_assessment_link(%AssessmentLink{}), do: {:error, :already_revoked}

  ## Session lifecycle

  @doc """
  Looks up the assessment link for a token and checks it can be started:
  unused, not revoked, and (for a candidate link) its recruiter link not
  revoked. This does **not** use the link up; `mark_started/2` does.
  """
  @spec begin_session(term()) ::
          {:ok, AssessmentLink.t()} | {:error, :not_found | :revoked | :started | :completed}
  def begin_session(token) when is_binary(token) do
    AssessmentLink
    |> Repo.get_by(token_hash: Token.hash(token))
    |> Repo.preload(:recruiter_link)
    |> check_startable()
  end

  def begin_session(_), do: {:error, :not_found}

  @doc """
  The assessment link for a token, whatever its state, with its recruiter
  link; nil if there is none. For carrying on a session already begun.
  """
  @spec get_assessment_link_by_token(term()) :: AssessmentLink.t() | nil
  def get_assessment_link_by_token(token) when is_binary(token) do
    AssessmentLink
    |> Repo.get_by(token_hash: Token.hash(token))
    |> Repo.preload(:recruiter_link)
  end

  def get_assessment_link_by_token(_), do: nil

  defp check_startable(nil), do: {:error, :not_found}
  defp check_startable(%AssessmentLink{revoked_at: %DateTime{}}), do: {:error, :revoked}
  defp check_startable(%AssessmentLink{status: :completed}), do: {:error, :completed}
  defp check_startable(%AssessmentLink{status: :started}), do: {:error, :started}

  defp check_startable(%AssessmentLink{recruiter_link: %RecruiterLink{revoked_at: %DateTime{}}}),
    do: {:error, :revoked}

  defp check_startable(%AssessmentLink{} = link), do: {:ok, link}

  @doc """
  Uses the link up. Call this only once the first question has been shown.

  `attrs` holds the mode (`:text` by default) and, for an individual link,
  the role group the person chose. The update is conditional on the link
  still being unused and unrevoked, so if two tabs start one link exactly
  one of them wins; the other gets `{:error, :already_started}`.
  """
  @spec mark_started(AssessmentLink.t(), map()) ::
          {:ok, AssessmentLink.t()} | {:error, :already_started | Ecto.Changeset.t()}
  def mark_started(%AssessmentLink{} = link, attrs \\ %{}) do
    changeset = AssessmentLink.start_changeset(link, attrs)

    with {:ok, started} <- Ecto.Changeset.apply_action(changeset, :update) do
      at = now()

      {count, _} =
        Repo.update_all(
          from(l in AssessmentLink,
            where: l.id == ^link.id and l.status == :unused and is_nil(l.revoked_at)
          ),
          set: [
            status: :started,
            started_at: at,
            role_group: started.role_group,
            mode: started.mode,
            updated_at: at
          ]
        )

      if count == 1,
        do: {:ok, %{started | status: :started, started_at: at, updated_at: at}},
        else: {:error, :already_started}
    end
  end

  @doc """
  Records that a recording was used for an answer: the link's mode turns
  to `:voice`. Only a link that has been used up; an unused one is left
  alone and gets `{:error, :not_started}`.
  """
  @spec mark_spoken(AssessmentLink.t()) :: {:ok, AssessmentLink.t()} | {:error, :not_started}
  def mark_spoken(%AssessmentLink{} = link) do
    at = now()

    {count, _} =
      Repo.update_all(
        from(l in AssessmentLink,
          where: l.id == ^link.id and l.status in [:started, :completed]
        ),
        set: [mode: :voice, updated_at: at]
      )

    if count == 1,
      do: {:ok, %{link | mode: :voice, updated_at: at}},
      else: {:error, :not_started}
  end

  @doc "Marks a started link completed, once the reports have been generated."
  @spec mark_completed(AssessmentLink.t()) ::
          {:ok, AssessmentLink.t()} | {:error, :not_started}
  def mark_completed(%AssessmentLink{} = link) do
    at = now()

    {count, _} =
      Repo.update_all(
        from(l in AssessmentLink, where: l.id == ^link.id and l.status == :started),
        set: [status: :completed, completed_at: at, updated_at: at]
      )

    if count == 1,
      do: {:ok, %{link | status: :completed, completed_at: at, updated_at: at}},
      else: {:error, :not_started}
  end

  ## Usage

  @doc """
  Where a link stands, for display: `:revoked` (an unused link withdrawn or
  revoked), `:unused`, `:started`, `:abandoned` (started more than an hour
  ago and not completed) or `:completed`.
  """
  @spec state(AssessmentLink.t(), DateTime.t()) :: state()
  def state(link, now \\ DateTime.utc_now())

  def state(%AssessmentLink{status: :unused, revoked_at: %DateTime{}}, _now), do: :revoked
  def state(%AssessmentLink{status: :unused}, _now), do: :unused
  def state(%AssessmentLink{status: :completed}, _now), do: :completed

  def state(%AssessmentLink{status: :started, started_at: started_at}, now) do
    if DateTime.diff(now, started_at) > @abandoned_after, do: :abandoned, else: :started
  end

  @doc """
  The admin usage table. For each recruiter link: candidate links minted,
  started (in progress), completed and abandoned, and quota used. For each
  individual link: its state.
  """
  @spec usage(DateTime.t()) :: %{recruiters: [map()], individuals: [map()]}
  def usage(now \\ DateTime.utc_now()) do
    candidates =
      Repo.all(from l in AssessmentLink, where: l.kind == :candidate)
      |> Enum.group_by(& &1.recruiter_link_id)

    recruiters =
      for recruiter <- list_recruiter_links() do
        links = Map.get(candidates, recruiter.id, [])
        states = Enum.frequencies_by(links, &state(&1, now))

        %{
          link: recruiter,
          minted: length(links),
          started: Map.get(states, :started, 0),
          completed: Map.get(states, :completed, 0),
          abandoned: Map.get(states, :abandoned, 0),
          quota_used: Map.get(states, :unused, 0) + Map.get(states, :completed, 0)
        }
      end

    individuals =
      for link <- list_individual_links(), do: %{link: link, state: state(link, now)}

    %{recruiters: recruiters, individuals: individuals}
  end

  @doc "The readable name of a role group, or nil."
  def role_group_name(nil), do: nil
  def role_group_name(group), do: RoleGroups.name(group)

  defp with_token({:ok, link}, token), do: {:ok, link, token}
  defp with_token({:error, changeset}, _token), do: {:error, changeset}

  defp now, do: DateTime.utc_now(:second)
end
