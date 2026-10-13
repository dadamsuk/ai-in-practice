defmodule AiInPractice.ReadingTest do
  use AiInPractice.DataCase

  alias AiInPractice.Reading
  alias AiInPractice.Reading.Item

  @valid %{
    title: "Co-Intelligence",
    url: "https://example.com/co-intelligence",
    role_groups: ["ceo_gm", "board_ned"],
    areas: ["personal_use", "attitude"],
    note: "A plain introduction for leaders.",
    last_checked_on: "2026-10-01"
  }

  test "create, read, update and delete" do
    assert {:ok, item} = Reading.create_item(@valid)
    assert item.role_groups == [:ceo_gm, :board_ned]
    assert item.areas == [:personal_use, :attitude]
    assert item.last_checked_on == ~D[2026-10-01]
    assert item.active

    assert Reading.get_item(item.id).title == "Co-Intelligence"
    assert {:ok, item} = Reading.update_item(item, %{title: "Co-Intelligence (2nd ed.)"})
    assert Reading.get_item(item.id).title == "Co-Intelligence (2nd ed.)"
    assert [%Item{}] = Reading.list_items()

    assert {:ok, _} = Reading.delete_item(item)
    assert Reading.get_item(item.id) == nil
  end

  test "needs a title, an http(s) URL and at least one area" do
    assert {:error, cs} = Reading.create_item(%{})
    assert %{title: [_], url: [_]} = errors_on(cs)

    assert {:error, cs} = Reading.create_item(%{@valid | areas: []})
    assert %{areas: ["choose at least one area"]} = errors_on(cs)

    for bad <- ["example.com/x", "javascript:alert(1)", "ftp://example.com", "https://"] do
      assert {:error, cs} = Reading.create_item(%{@valid | url: bad})
      assert %{url: ["must be a full http or https address"]} = errors_on(cs), bad
    end
  end

  test "refuses unknown areas and role groups" do
    assert {:error, cs} = Reading.create_item(%{@valid | areas: ["juggling"]})
    assert errors_on(cs)[:areas]

    assert {:error, cs} = Reading.create_item(%{@valid | role_groups: ["astronaut"]})
    assert errors_on(cs)[:role_groups]
  end

  test "role groups are optional: an entry can suit everyone" do
    assert {:ok, item} = Reading.create_item(%{@valid | role_groups: []})
    assert item.role_groups == []
  end

  test "inactive entries are left out of what the report generator gets" do
    {:ok, a} = Reading.create_item(@valid)
    {:ok, b} = Reading.create_item(%{@valid | title: "Retired", url: "https://example.com/old"})
    {:ok, _} = Reading.update_item(b, %{active: false})

    assert Reading.active_ids() == [a.id]
    assert [%Item{id: id}] = Reading.active_items()
    assert id == a.id
    assert length(Reading.list_items()) == 2
  end

  test "the areas are the rubric's five" do
    assert Item.areas() ==
             [:understanding, :personal_use, :applying_to_business, :leading_adoption, :attitude]
  end
end
