defmodule AiInPractice.Links.SchemaTest do
  use AiInPractice.DataCase

  import AiInPractice.LinksFixtures

  alias AiInPractice.Links
  alias AiInPractice.Links.{AssessmentLink, RecruiterLink, Token}
  alias AiInPractice.RoleGroups
  alias AiInPracticeWeb.Plugs.RequestLogger

  describe "tokens" do
    test "are 52 lower-case base32 characters (256 bits), long enough to be redacted from logs" do
      token = Token.generate()
      assert String.length(token) == 52
      assert token =~ ~r/\A[a-z2-7]{52}\z/

      assert RequestLogger.redact_path("/r/#{token}") ==
               "/r/[redacted]"
    end

    test "are unique" do
      tokens = for _ <- 1..1000, do: Token.generate()
      assert tokens |> Enum.uniq() |> length() == 1000
    end

    test "only a SHA-256 hash is stored, never the token" do
      {recruiter, r_token} = recruiter_link_fixture()
      {candidate, c_token} = candidate_link_fixture(recruiter)

      assert Repo.get!(RecruiterLink, recruiter.id).token_hash ==
               :crypto.hash(:sha256, r_token)

      assert Repo.get!(AssessmentLink, candidate.id).token_hash ==
               :crypto.hash(:sha256, c_token)

      for table <- ["recruiter_links", "assessment_links"] do
        %{rows: rows} = Repo.query!("SELECT * FROM #{table}")
        dump = inspect(rows, limit: :infinity, printable_limit: :infinity)
        refute dump =~ r_token
        refute dump =~ c_token
      end
    end
  end

  describe "recruiter link changeset" do
    test "needs a firm, contact name and a valid email" do
      cs = Links.change_recruiter_link(%{quota: 10})
      refute cs.valid?

      assert %{firm_name: [_], contact_name: [_], contact_email: [_]} = errors_on(cs)

      cs = Links.change_recruiter_link(%{firm_name: "F", contact_name: "C", contact_email: "x"})
      assert %{contact_email: ["must be an email address"]} = errors_on(cs)
    end

    test "quota defaults to 10 and must be between 0 and 100" do
      assert {:ok, link, _} =
               Links.create_recruiter_link(%{
                 firm_name: "F",
                 contact_name: "C",
                 contact_email: "c@f.example"
               })

      assert link.quota == 10

      for bad <- [-1, 101, "lots"] do
        cs = Links.change_recruiter_link(%{quota: bad})
        assert errors_on(cs)[:quota], "quota #{inspect(bad)} accepted"
      end
    end

    test "trims whitespace" do
      {link, _} = recruiter_link_fixture(%{firm_name: "  Northgate  "})
      assert link.firm_name == "Northgate"
    end
  end

  describe "candidate link changeset" do
    test "needs a recruiter and a role group" do
      cs = AssessmentLink.candidate_changeset(%AssessmentLink{}, %{})
      assert %{recruiter_link_id: [_], role_group: [_]} = errors_on(cs)
    end

    test "does not take a label" do
      cs =
        AssessmentLink.candidate_changeset(%AssessmentLink{}, %{
          recruiter_link_id: 1,
          role_group: :finance,
          label: "AB"
        })

      assert Ecto.Changeset.get_change(cs, :label) == nil
      assert Ecto.Changeset.get_change(cs, :kind) == :candidate
    end

    test "the database refuses a recruiter that does not exist" do
      cs =
        AssessmentLink.candidate_changeset(%AssessmentLink{}, %{
          recruiter_link_id: -1,
          role_group: :finance
        })
        |> AssessmentLink.put_token_hash(Token.hash(Token.generate()))

      # SQLite does not name the failed foreign key, so this raises rather
      # than returning a changeset error. Links only mints from a loaded
      # recruiter link, so it is never reached in practice.
      assert_raise Ecto.ConstraintError, fn -> Repo.insert(cs) end
    end
  end

  describe "quick links" do
    test "an individual link is full-length by default and may be made quick" do
      assert {:ok, link, _} = Links.create_individual_link(%{label: "IND-1"})
      assert Repo.get!(AssessmentLink, link.id).quick == false

      assert {:ok, link, _} = Links.create_individual_link(%{label: "IND-2", quick: "true"})
      assert Repo.get!(AssessmentLink, link.id).quick == true
    end

    test "quick must be a boolean" do
      cs = AssessmentLink.individual_changeset(%AssessmentLink{}, %{label: "X", quick: "soon"})
      assert %{quick: ["is invalid"]} = errors_on(cs)
    end

    test "a candidate link can never be quick" do
      {recruiter, _} = recruiter_link_fixture()

      cs =
        AssessmentLink.candidate_changeset(%AssessmentLink{}, %{
          recruiter_link_id: recruiter.id,
          role_group: :finance,
          quick: true
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :quick) == false
    end
  end

  describe "individual link changeset" do
    test "needs a label of at most 40 characters" do
      assert %{label: [_]} = errors_on(Links.change_individual_link(%{}))
      assert %{label: [_]} = errors_on(Links.change_individual_link(%{label: "   "}))

      assert %{label: ["should be at most 40 character(s)"]} =
               errors_on(Links.change_individual_link(%{label: String.duplicate("x", 41)}))
    end

    test "never takes a recruiter, and leaves the role group to the person" do
      {:ok, link, _} = Links.create_individual_link(%{label: "IND-014", recruiter_link_id: 1})
      assert link.kind == :individual
      assert link.recruiter_link_id == nil
      assert link.role_group == nil
      assert link.status == :unused
    end
  end

  describe "role groups" do
    test "are the seven from the PRD" do
      assert RoleGroups.all() ==
               [
                 :ceo_gm,
                 :finance,
                 :operations,
                 :commercial,
                 :people,
                 :technology_product,
                 :board_ned
               ]

      assert length(RoleGroups.options()) == 7
      assert RoleGroups.name(:board_ned) =~ "non-executive"
    end

    test "parse refuses unknown values" do
      assert RoleGroups.parse("finance") == {:ok, :finance}
      assert RoleGroups.parse(:people) == {:ok, :people}
      assert RoleGroups.parse("astronaut") == :error
      assert RoleGroups.parse(:astronaut) == :error
      assert RoleGroups.parse(nil) == :error
    end

    test "the schema rejects an unknown role group" do
      {recruiter, _} = recruiter_link_fixture()

      cs =
        AssessmentLink.candidate_changeset(%AssessmentLink{}, %{
          recruiter_link_id: recruiter.id,
          role_group: "astronaut"
        })

      assert %{role_group: ["is invalid"]} = errors_on(cs)
      assert {:error, %Ecto.Changeset{}} = Links.mint_candidate_link(recruiter, "astronaut")
    end
  end

  @tag :privacy
  test "no table has a column for a candidate's identity, transcript or report" do
    %{rows: tables} =
      Repo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
      )

    forbidden =
      ~r/transcript|answer|report|question|audio|candidate_name|first_name|last_name|phone|address|^name$|^email$|summary|quote|content|body|text$/

    columns =
      for [table] <- tables,
          %{rows: cols} = Repo.query!("PRAGMA table_info(#{table})"),
          [_, column | _] <- cols,
          do: {table, column}

    assert {"assessment_links", "status"} in columns

    for {table, column} <- columns do
      refute column =~ forbidden, "#{table}.#{column} looks like it could hold session data"
    end

    # The only contact details kept are the recruiter's, entered by David.
    assert for({t, c} <- columns, c =~ ~r/email|contact/, do: t) |> Enum.uniq() ==
             ["recruiter_links"]
  end
end
