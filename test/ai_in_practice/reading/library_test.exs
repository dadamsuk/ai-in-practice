defmodule AiInPractice.Reading.LibraryTest do
  use AiInPractice.DataCase

  alias AiInPractice.Reading
  alias AiInPractice.Reading.{Item, Library}

  @moduletag :tmp_dir

  defp resource(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "title" => "Title #{id}",
        "author" => "An Author",
        "format" => "Article",
        "url" => "https://example.com/#{id}",
        "description" => "What #{id} is.",
        "level" => ["Beginner"],
        "audience" => ["All senior leaders"],
        "focus" => ["Personal productivity"],
        "cost" => "Free"
      },
      attrs
    )
  end

  defp write!(dir, resources, extra \\ %{}) do
    path = Path.join(dir, "library-#{System.unique_integer([:positive])}.json")
    json = Map.merge(%{"linksCheckedOn" => "2026-10-13", "resources" => resources}, extra)
    File.write!(path, Jason.encode!(json))
    path
  end

  defp by_slug(slug), do: Repo.get_by!(Item, slug: slug)

  test "the shipped library imports in full, every entry tagged to at least one area", %{} do
    assert {:ok, %{added: 64, updated: 0, deactivated: 0, total: 64}} = Library.load()
    items = Reading.active_items()
    assert length(items) == 64
    assert Enum.all?(items, &(&1.areas != [] and &1.last_checked_on == ~D[2026-10-13]))

    nb = by_slug("how-i-use-llms")
    assert nb.author == "Andrej Karpathy, 2025"
    assert nb.format == "Video"
    assert nb.cost == "Free"
    assert nb.levels == ["Intermediate"]
    assert nb.role_groups == []
    assert nb.areas == [:understanding, :personal_use]
    assert nb.note =~ "Two hours of an expert's real daily use"
  end

  test "importing again updates in place: ids are kept", %{tmp_dir: dir} do
    path = write!(dir, [resource("a"), resource("b")])
    assert {:ok, %{added: 2}} = Library.load(path)
    id = by_slug("a").id

    path = write!(dir, [resource("a", %{"title" => "New title"}), resource("b")])
    assert {:ok, %{added: 0, updated: 2, deactivated: 0, total: 2}} = Library.load(path)
    assert by_slug("a").id == id
    assert by_slug("a").title == "New title"
  end

  test "an entry dropped from the library goes inactive; hand-made entries are left alone",
       %{tmp_dir: dir} do
    {:ok, manual} =
      Reading.create_item(%{title: "By hand", url: "https://example.com/m", areas: [:attitude]})

    assert {:ok, _} = Library.load(write!(dir, [resource("a"), resource("b")]))
    assert {:ok, %{deactivated: 1}} = Library.load(write!(dir, [resource("a")]))

    refute by_slug("b").active
    assert by_slug("a").active
    assert Repo.get!(Item, manual.id).active

    # Back in the file, it is active again.
    assert {:ok, %{updated: 2}} = Library.load(write!(dir, [resource("a"), resource("b")]))
    assert by_slug("b").active
  end

  test "a resource that does not validate changes nothing", %{tmp_dir: dir} do
    assert {:ok, _} = Library.load(write!(dir, [resource("a")]))

    bad =
      write!(dir, [resource("a", %{"title" => "Changed"}), resource("c", %{"url" => "ftp://x"})])

    assert {:error, message} = Library.load(bad)
    assert message =~ ~s(resource "c")
    assert message =~ "url"

    assert by_slug("a").title == "Title a"
    refute Repo.get_by(Item, slug: "c")
  end

  test "an unknown level is refused", %{tmp_dir: dir} do
    assert {:error, message} =
             Library.load(write!(dir, [resource("a", %{"level" => ["Expert"]})]))

    assert message =~ "levels"
  end

  test "a missing, unreadable or shapeless file is an error", %{tmp_dir: dir} do
    assert {:error, message} = Library.load(Path.join(dir, "missing.json"))
    assert message =~ "cannot read"

    path = Path.join(dir, "bad.json")
    File.write!(path, "{not json")
    assert {:error, message} = Library.load(path)
    assert message =~ "not valid JSON"

    path = Path.join(dir, "shapeless.json")
    File.write!(path, ~s({"items": []}))
    assert {:error, message} = Library.load(path)
    assert message =~ ~s(no "resources" list)
  end

  test "a bad links-checked date is left empty", %{tmp_dir: dir} do
    assert {:ok, _} = Library.load(write!(dir, [resource("a")], %{"linksCheckedOn" => "soon"}))
    assert by_slug("a").last_checked_on == nil
  end

  describe "mapping the library's tags" do
    test "audiences to role groups; all senior leaders means every role" do
      assert Library.role_groups(["All senior leaders", "Technology leaders"]) == []
      assert Library.role_groups(["Board & non-executives"]) == [:board_ned]
      assert Library.role_groups(["CEO & executive team"]) == [:ceo_gm]

      assert Library.role_groups(["Functional leaders"]) ==
               [:finance, :operations, :commercial, :people]

      assert Library.role_groups(["Risk, legal & compliance", "Technology leaders"]) ==
               [:finance, :operations, :technology_product]

      assert Library.role_groups(["Someone new"]) == []
    end

    test "focus to the rubric's areas, in rubric order, without repeats" do
      assert Library.areas(["Personal productivity"]) == [:personal_use]

      assert Library.areas(["Workforce & change", "How AI works"]) == [
               :understanding,
               :leading_adoption
             ]

      assert Library.areas(["Market context"]) == [:attitude]
      assert Library.areas(["Strategy", "Use-case selection"]) == [:applying_to_business]
      assert Library.areas(["Unknown"]) == []
    end
  end
end
