defmodule AiInPractice.LinksCLITest do
  use AiInPractice.DataCase

  import ExUnit.CaptureIO
  import AiInPractice.LinksFixtures

  alias AiInPractice.Links
  alias AiInPractice.LinksCLI

  defp token_from(out),
    do: Regex.run(~r"/(?:r|a)/([a-z2-7]{52})", out, capture: :all_but_first) |> hd()

  describe "recruiter" do
    test "creates a recruiter link and prints its URL once" do
      assert {:ok, out} =
               LinksCLI.run(
                 ~w(recruiter --firm Northgate --contact Sam --email sam@n.example --quota 5)
               )

      assert out =~ "for Northgate, quota 5"
      assert out =~ "shown only once"
      recruiter = out |> token_from() |> Links.get_recruiter_link_by_token()
      assert recruiter.quota == 5
      assert recruiter.contact_email == "sam@n.example"
    end

    test "defaults the quota to 10" do
      {:ok, out} = LinksCLI.run(~w(recruiter --firm F --contact C --email c@f.example))
      assert (out |> token_from() |> Links.get_recruiter_link_by_token()).quota == 10
    end

    test "reports validation errors" do
      assert {:error, message} = LinksCLI.run(~w(recruiter --firm F --email nope --quota x))
      assert message =~ "contact_name can't be blank"
      assert message =~ "contact_email must be an email address"
      assert message =~ "quota is invalid"
      assert Links.list_recruiter_links() == []
    end

    test "refuses unknown options" do
      assert {:error, message} = LinksCLI.run(~w(recruiter --firm F --colour red))
      assert message =~ "usage:"
    end
  end

  describe "individual" do
    test "creates an individual link" do
      assert {:ok, out} = LinksCLI.run(~w(individual --label IND-014))
      assert out =~ "IND-014"
      assert {:ok, %{label: "IND-014"}} = out |> token_from() |> Links.begin_session()
    end

    test "is full-length unless --quick is given" do
      assert {:ok, out} = LinksCLI.run(~w(individual --label IND-015))
      refute out =~ "quick"
      assert {:ok, %{quick: false}} = out |> token_from() |> Links.begin_session()
    end

    test "--quick makes a quick link and says so" do
      assert {:ok, out} = LinksCLI.run(~w(individual --label IND-016 --quick))
      assert out =~ "IND-016 (quick)"
      assert {:ok, %{quick: true}} = out |> token_from() |> Links.begin_session()
    end

    test "--quick takes no value" do
      assert {:error, message} = LinksCLI.run(~w(individual --label IND-017 --quick yes))
      assert message =~ "individual --label LABEL [--quick]"
    end

    test "needs a label" do
      assert {:error, "label can't be blank\n"} = LinksCLI.run(~w(individual))
      assert {:error, "label can't be blank\n"} = LinksCLI.run(~w(individual --quick))
    end
  end

  describe "quota" do
    test "sets a quota" do
      {r, _} = recruiter_link_fixture()
      assert {:ok, out} = LinksCLI.run(["quota", "#{r.id}", "20"])
      assert out =~ "is now 20"
      assert Links.get_recruiter_link(r.id).quota == 20
    end

    test "refuses an invalid quota or an unknown id" do
      {r, _} = recruiter_link_fixture()
      assert {:error, m} = LinksCLI.run(["quota", "#{r.id}", "-1"])
      assert m =~ "quota must be greater than or equal to 0"
      assert {:error, m} = LinksCLI.run(["quota", "#{r.id}", "lots"])
      assert m =~ "quota is invalid"
      assert Links.get_recruiter_link(r.id).quota == 10

      assert {:error, "no recruiter link with id 999999\n"} = LinksCLI.run(~w(quota 999999 5))
      assert {:error, "no recruiter link with id abc\n"} = LinksCLI.run(~w(quota abc 5))
    end
  end

  describe "revoke" do
    test "revokes a recruiter link, then refuses to do it again" do
      {r, _} = recruiter_link_fixture()
      assert {:ok, out} = LinksCLI.run(["revoke", "recruiter", "#{r.id}"])
      assert out =~ "revoked recruiter link #{r.id}"
      assert Links.get_recruiter_link(r.id).revoked_at

      assert LinksCLI.run(["revoke", "recruiter", "#{r.id}"]) ==
               {:error, "that link is already revoked\n"}
    end

    test "revokes an assessment link, then refuses to do it again" do
      {link, token} = individual_link_fixture()
      assert {:ok, _} = LinksCLI.run(["revoke", "link", "#{link.id}"])
      assert Links.begin_session(token) == {:error, :revoked}

      assert LinksCLI.run(["revoke", "link", "#{link.id}"]) ==
               {:error, "that link is already revoked\n"}
    end

    test "an unknown id" do
      assert {:error, "no link link with id 42\n"} = LinksCLI.run(~w(revoke link 42))
    end
  end

  test "usage prints both tables" do
    {r, _} = recruiter_link_fixture(%{firm_name: "Northgate", quota: 3})
    {c, _} = candidate_link_fixture(r)
    {:ok, c} = Links.mark_started(c)
    backdate_start(c, 7200)
    candidate_link_fixture(r)
    individual_link_fixture("IND-7")

    assert {:ok, out} = LinksCLI.run(["usage"])

    [recruiter_line] = out |> String.split("\n") |> Enum.filter(&(&1 =~ "Northgate"))

    assert String.split(recruiter_line) == [
             "#{r.id}",
             "Northgate",
             "2",
             "0",
             "0",
             "1",
             "1/3",
             "open"
           ]

    assert out =~ ~r/IND-7\s+full\s+unused/
    assert out =~ ~r/id\s+label\s+length\s+status/

    {:ok, _} = LinksCLI.run(~w(individual --label IND-Q --quick))
    assert {:ok, out} = LinksCLI.run(["usage"])
    assert out =~ ~r/IND-Q\s+quick\s+unused/
  end

  test "unknown commands print usage" do
    assert {:error, message} = LinksCLI.run(["frobnicate"])
    assert message =~ "links usage"
    assert {:error, _} = LinksCLI.run([])
  end

  describe "rpc/1 and bin/links" do
    test "decodes base64 arguments, so spaces and quotes survive" do
      args = ["individual", "--label", ~s(IND "one" two)]
      encoded = Enum.map_join(args, " ", &Base.encode64/1)

      out = capture_io(fn -> LinksCLI.rpc(" " <> encoded) end)
      assert out =~ ~s(IND "one" two)
      assert [%{label: ~s(IND "one" two)}] = Links.list_individual_links()
    end

    test "prints errors" do
      assert capture_io(fn -> LinksCLI.rpc(Base.encode64("nope")) end) =~ "error: usage:"
    end

    @tag :tmp_dir
    test "the release script encodes each argument for rpc", %{tmp_dir: dir} do
      File.cp!("rel/overlays/bin/links", Path.join(dir, "links"))
      stub = Path.join(dir, "ai_in_practice")
      File.write!(stub, ~s(#!/bin/sh\nprintf '%s\\n' "$1" "$2"\n))
      File.chmod!(stub, 0o755)
      File.chmod!(Path.join(dir, "links"), 0o755)

      awkward = "O'Brien \"and\" Co $(echo pwned) \\"
      {out, 0} = System.cmd(Path.join(dir, "links"), ["recruiter", "--firm", awkward])

      [command, expr] = String.split(out, "\n", trim: true)
      assert command == "rpc"
      [_, encoded] = Regex.run(~r/\AAiInPractice\.LinksCLI\.rpc\("([A-Za-z0-9+\/= ]*)"\)\z/, expr)

      assert encoded |> String.split() |> Enum.map(&Base.decode64!/1) ==
               ["recruiter", "--firm", awkward]
    end
  end
end
