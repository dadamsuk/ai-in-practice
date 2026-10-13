defmodule AiInPractice.Links.LifecycleTest do
  use AiInPractice.DataCase

  import AiInPractice.LinksFixtures

  alias AiInPractice.Links
  alias AiInPractice.Links.{AssessmentLink, Token}

  describe "begin_session/1" do
    test "accepts an unused candidate link without using it up" do
      {recruiter, _} = recruiter_link_fixture()
      {link, token} = candidate_link_fixture(recruiter)

      assert {:ok, %AssessmentLink{id: id, status: :unused}} = Links.begin_session(token)
      assert id == link.id
      assert Repo.get!(AssessmentLink, id).status == :unused
      assert Repo.get!(AssessmentLink, id).started_at == nil
    end

    test "a failure before the first question leaves the link usable" do
      {_, token} = individual_link_fixture()
      assert {:ok, _} = Links.begin_session(token)
      # ... the model call fails here, so mark_started/2 is never called ...
      assert {:ok, %AssessmentLink{status: :unused}} = Links.begin_session(token)
    end

    test "refuses an unknown or malformed token" do
      assert Links.begin_session(Token.generate()) == {:error, :not_found}
      assert Links.begin_session("") == {:error, :not_found}
      assert Links.begin_session(nil) == {:error, :not_found}
    end

    test "a recruiter token is not an assessment token" do
      {_, r_token} = recruiter_link_fixture()
      assert Links.begin_session(r_token) == {:error, :not_found}
    end

    test "refuses a started link, which can never be reopened" do
      {link, token} = individual_link_fixture()
      {:ok, _} = Links.mark_started(link, %{role_group: :people})
      assert Links.begin_session(token) == {:error, :started}

      backdate_start(link, 3 * 60 * 60)
      assert Links.begin_session(token) == {:error, :started}
    end

    test "refuses a completed link" do
      {link, token} = individual_link_fixture()
      {:ok, link} = Links.mark_started(link, %{role_group: :people})
      {:ok, _} = Links.mark_completed(link)
      assert Links.begin_session(token) == {:error, :completed}
    end

    test "refuses a revoked link" do
      {link, token} = individual_link_fixture()
      {:ok, _} = Links.revoke_assessment_link(link)
      assert Links.begin_session(token) == {:error, :revoked}
    end

    test "refuses an unused candidate link whose recruiter link is revoked" do
      {recruiter, _} = recruiter_link_fixture()
      {_, token} = candidate_link_fixture(recruiter)
      {:ok, _} = Links.revoke_recruiter_link(recruiter)
      assert Links.begin_session(token) == {:error, :revoked}
    end
  end

  describe "mark_started/2" do
    test "uses the link up, recording the time and mode" do
      {recruiter, _} = recruiter_link_fixture()
      {link, _} = candidate_link_fixture(recruiter, :commercial)

      assert {:ok, started} = Links.mark_started(link)
      assert started.status == :started
      assert started.mode == :text
      assert started.role_group == :commercial

      stored = Repo.get!(AssessmentLink, link.id)
      assert stored.status == :started
      assert stored.mode == :text
      assert %DateTime{} = stored.started_at
    end

    test "a candidate link keeps the recruiter's role group" do
      {recruiter, _} = recruiter_link_fixture()
      {link, _} = candidate_link_fixture(recruiter, :commercial)
      {:ok, _} = Links.mark_started(link, %{role_group: :finance})
      assert Repo.get!(AssessmentLink, link.id).role_group == :commercial
    end

    test "an individual link records the role group the person chose" do
      {link, _} = individual_link_fixture()
      assert {:ok, _} = Links.mark_started(link, %{role_group: "board_ned", mode: "text"})
      assert Repo.get!(AssessmentLink, link.id).role_group == :board_ned
    end

    test "an individual link cannot start without a valid role group" do
      {link, _} = individual_link_fixture()
      assert {:error, %Ecto.Changeset{} = cs} = Links.mark_started(link)
      assert %{role_group: [_]} = errors_on(cs)

      assert {:error, cs} = Links.mark_started(link, %{role_group: "astronaut"})
      assert %{role_group: ["is invalid"]} = errors_on(cs)

      assert Repo.get!(AssessmentLink, link.id).status == :unused
    end

    test "with two tabs starting one link at once, exactly one wins" do
      {link, token} = individual_link_fixture()
      {:ok, tab_a} = Links.begin_session(token)
      {:ok, tab_b} = Links.begin_session(token)

      results =
        [tab_a, tab_b]
        |> Enum.map(fn tab ->
          Task.async(fn -> Links.mark_started(tab, %{role_group: :people}) end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert {:error, :already_started} in results
      assert Repo.get!(AssessmentLink, link.id).status == :started
    end

    test "a started link cannot be started again" do
      {link, _} = individual_link_fixture()
      {:ok, _} = Links.mark_started(link, %{role_group: :people})
      assert Links.mark_started(link, %{role_group: :people}) == {:error, :already_started}
    end

    test "a completed link cannot be reused" do
      {link, token} = individual_link_fixture()
      {:ok, started} = Links.mark_started(link, %{role_group: :people})
      {:ok, _} = Links.mark_completed(started)

      assert Links.mark_started(link, %{role_group: :people}) == {:error, :already_started}
      assert Links.begin_session(token) == {:error, :completed}
    end

    test "a link revoked after begin_session cannot be started" do
      {link, token} = individual_link_fixture()
      {:ok, link_in_session} = Links.begin_session(token)
      {:ok, _} = Links.revoke_assessment_link(link)

      assert Links.mark_started(link_in_session, %{role_group: :people}) ==
               {:error, :already_started}
    end
  end

  describe "mark_completed/1" do
    test "completes a started link" do
      {link, _} = individual_link_fixture()
      {:ok, started} = Links.mark_started(link, %{role_group: :people})
      assert {:ok, %{status: :completed}} = Links.mark_completed(started)

      stored = Repo.get!(AssessmentLink, link.id)
      assert stored.status == :completed
      assert %DateTime{} = stored.completed_at
    end

    test "refuses an unused or already completed link" do
      {link, _} = individual_link_fixture()
      assert Links.mark_completed(link) == {:error, :not_started}

      {:ok, started} = Links.mark_started(link, %{role_group: :people})
      {:ok, _} = Links.mark_completed(started)
      assert Links.mark_completed(started) == {:error, :not_started}
    end
  end

  describe "quota" do
    test "the 10th candidate link is allowed and the 11th refused" do
      {recruiter, _} = recruiter_link_fixture(%{quota: 10})

      for n <- 1..10 do
        assert {:ok, _, _} = Links.mint_candidate_link(recruiter, :finance), "mint #{n} refused"
      end

      assert Links.quota_used(recruiter) == 10
      assert Links.quota_remaining(recruiter) == 0
      assert Links.mint_candidate_link(recruiter, :finance) == {:error, :quota_reached}
      assert length(Links.list_candidate_links(recruiter)) == 10
    end

    test "an abandoned link frees a slot; a completed one does not" do
      {recruiter, _} = recruiter_link_fixture(%{quota: 2})
      {a, _} = candidate_link_fixture(recruiter)
      {b, _} = candidate_link_fixture(recruiter)
      assert Links.mint_candidate_link(recruiter, :finance) == {:error, :quota_reached}

      {:ok, a} = Links.mark_started(a)
      {:ok, _} = Links.mark_completed(a)
      assert Links.mint_candidate_link(recruiter, :finance) == {:error, :quota_reached}

      # b is started and never completed: it no longer counts.
      {:ok, _} = Links.mark_started(b)
      assert Links.quota_used(recruiter) == 1
      assert {:ok, _, _} = Links.mint_candidate_link(recruiter, :finance)
      assert Links.mint_candidate_link(recruiter, :finance) == {:error, :quota_reached}
    end

    test "a withdrawn unused link frees a slot" do
      {recruiter, _} = recruiter_link_fixture(%{quota: 1})
      {a, _} = candidate_link_fixture(recruiter)
      assert Links.mint_candidate_link(recruiter, :finance) == {:error, :quota_reached}

      assert {:ok, _} = Links.withdraw_candidate_link(recruiter, a.id)
      assert {:ok, _, _} = Links.mint_candidate_link(recruiter, :finance)
    end

    test "a raised quota allows more, a lowered one refuses" do
      {recruiter, _} = recruiter_link_fixture(%{quota: 1})
      candidate_link_fixture(recruiter)
      assert Links.mint_candidate_link(recruiter, :finance) == {:error, :quota_reached}

      {:ok, recruiter} = Links.set_quota(recruiter, 2)
      assert {:ok, _, _} = Links.mint_candidate_link(recruiter, :finance)

      {:ok, recruiter} = Links.set_quota(recruiter, 0)
      assert Links.quota_remaining(recruiter) == 0
      assert Links.mint_candidate_link(recruiter, :finance) == {:error, :quota_reached}
    end

    test "mint reads the current quota, not the caller's stale copy" do
      {recruiter, _} = recruiter_link_fixture(%{quota: 1})
      {:ok, _} = Links.set_quota(recruiter, 2)
      candidate_link_fixture(recruiter)
      assert {:ok, _, _} = Links.mint_candidate_link(recruiter, :finance)
    end

    test "set_quota refuses an invalid quota" do
      {recruiter, _} = recruiter_link_fixture()

      for bad <- [-1, 101, "many", nil] do
        assert {:error, %Ecto.Changeset{}} = Links.set_quota(recruiter, bad)
      end

      assert Links.get_recruiter_link(recruiter.id).quota == 10
    end

    test "a revoked recruiter link cannot mint" do
      {recruiter, _} = recruiter_link_fixture()
      {:ok, _} = Links.revoke_recruiter_link(recruiter)
      assert Links.mint_candidate_link(recruiter, :finance) == {:error, :revoked}
    end

    test "individual links have no quota" do
      for n <- 1..15, do: individual_link_fixture("IND-#{n}")
      assert length(Links.list_individual_links()) == 15
    end
  end

  describe "withdraw_candidate_link/2" do
    test "only the recruiter's own unused links" do
      {recruiter, _} = recruiter_link_fixture()
      {other, _} = recruiter_link_fixture(%{firm_name: "Other"})
      {theirs, _} = candidate_link_fixture(other)
      {started, _} = candidate_link_fixture(recruiter)
      {:ok, _} = Links.mark_started(started)

      assert Links.withdraw_candidate_link(recruiter, theirs.id) == {:error, :not_found}
      assert Links.withdraw_candidate_link(recruiter, -1) == {:error, :not_found}
      assert Links.withdraw_candidate_link(recruiter, started.id) == {:error, :not_unused}

      {unused, _} = candidate_link_fixture(recruiter)
      assert {:ok, _} = Links.withdraw_candidate_link(recruiter, unused.id)
      assert Links.withdraw_candidate_link(recruiter, unused.id) == {:error, :not_unused}
    end
  end

  describe "revoking" do
    test "twice is an error" do
      {recruiter, _} = recruiter_link_fixture()
      {:ok, recruiter} = Links.revoke_recruiter_link(recruiter)
      assert Links.revoke_recruiter_link(recruiter) == {:error, :already_revoked}

      {link, _} = individual_link_fixture()
      {:ok, link} = Links.revoke_assessment_link(link)
      assert Links.revoke_assessment_link(link) == {:error, :already_revoked}
    end
  end

  describe "state/2 and usage/1" do
    test "a started link is abandoned after an hour" do
      {link, _} = individual_link_fixture()
      {:ok, link} = Links.mark_started(link, %{role_group: :people})
      assert Links.state(link) == :started
      assert Links.state(backdate_start(link, 59 * 60)) == :started
      assert Links.state(backdate_start(link, 61 * 60)) == :abandoned
    end

    test "counts per recruiter and states per individual link" do
      {recruiter, _} = recruiter_link_fixture(%{quota: 10})
      {quiet, _} = recruiter_link_fixture(%{firm_name: "Quiet"})

      {_unused, _} = candidate_link_fixture(recruiter)
      {withdrawn, _} = candidate_link_fixture(recruiter)
      {:ok, _} = Links.withdraw_candidate_link(recruiter, withdrawn.id)
      {in_progress, _} = candidate_link_fixture(recruiter)
      {:ok, _} = Links.mark_started(in_progress)
      {abandoned, _} = candidate_link_fixture(recruiter)
      {:ok, abandoned} = Links.mark_started(abandoned)
      backdate_start(abandoned, 2 * 60 * 60)
      {done, _} = candidate_link_fixture(recruiter)
      {:ok, done} = Links.mark_started(done)
      {:ok, _} = Links.mark_completed(done)

      {ind_unused, _} = individual_link_fixture("IND-1")
      {ind_done, _} = individual_link_fixture("IND-2")
      {:ok, ind_done} = Links.mark_started(ind_done, %{role_group: :people})
      {:ok, _} = Links.mark_completed(ind_done)
      {ind_revoked, _} = individual_link_fixture("IND-3")
      {:ok, _} = Links.revoke_assessment_link(ind_revoked)

      %{recruiters: recruiters, individuals: individuals} = Links.usage()

      row = Enum.find(recruiters, &(&1.link.id == recruiter.id))

      assert Map.take(row, [:minted, :started, :completed, :abandoned, :quota_used]) == %{
               minted: 5,
               started: 1,
               completed: 1,
               abandoned: 1,
               quota_used: 2
             }

      assert Links.quota_used(recruiter) == row.quota_used

      quiet_row = Enum.find(recruiters, &(&1.link.id == quiet.id))
      assert quiet_row.minted == 0

      states = Map.new(individuals, &{&1.link.id, &1.state})
      assert states[ind_unused.id] == :unused
      assert states[ind_done.id] == :completed
      assert states[ind_revoked.id] == :revoked
      refute Enum.any?(individuals, &(&1.link.kind == :candidate))
    end
  end
end
