defmodule AiInPracticeWeb.Admin.ReadingLiveTest do
  use AiInPracticeWeb.ConnCase

  import Phoenix.LiveViewTest

  alias AiInPractice.Reading

  @endpoint AiInPracticeWeb.AdminEndpoint

  @entry %{
    title: "Co-Intelligence",
    url: "https://example.com/co-intelligence",
    areas: ["personal_use"],
    role_groups: ["ceo_gm"],
    note: "Plain and practical.",
    last_checked_on: "2026-10-01",
    active: "true"
  }

  test "adds an entry", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin/reading")
    html = view |> form("#item-form", item: @entry) |> render_submit()
    assert html =~ "Saved Co-Intelligence."

    [item] = Reading.list_items()
    assert item.areas == [:personal_use]
    assert item.role_groups == [:ceo_gm]
    assert view |> element("#item-#{item.id}") |> render() =~ "personal use"
    assert view |> element("#item-#{item.id}") |> render() =~ "2026-10-01"
  end

  test "an entry with no role groups suits everyone", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin/reading")
    view |> form("#item-form", item: Map.delete(@entry, :role_groups)) |> render_submit()
    [item] = Reading.list_items()
    assert item.role_groups == []
    assert view |> element("#item-#{item.id}") |> render() =~ "all role groups"
  end

  test "shows validation errors", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin/reading")

    html =
      view
      |> form("#item-form", item: %{@entry | url: "not a url"} |> Map.delete(:areas))
      |> render_submit()

    assert html =~ "must be a full http or https address"
    assert html =~ "choose at least one area"
    assert Reading.list_items() == []

    assert view |> form("#item-form", item: %{title: ""}) |> render_change() =~
             "can&#39;t be blank"
  end

  test "edits an entry and makes it inactive", %{conn: conn} do
    {:ok, item} = Reading.create_item(@entry)
    {:ok, view, _} = live(conn, "/admin/reading")

    assert view |> element("#item-#{item.id} button", "Edit") |> render_click() =~
             "Edit entry #{item.id}"

    view
    |> form("#item-form", item: %{title: "Co-Intelligence, 2nd ed.", active: "false"})
    |> render_submit()

    assert Reading.get_item(item.id).title == "Co-Intelligence, 2nd ed."
    assert view |> element("#item-#{item.id} [data-status]") |> render() =~ "inactive"
    assert Reading.active_ids() == []
  end

  test "cancel leaves an edit", %{conn: conn} do
    {:ok, item} = Reading.create_item(@entry)
    {:ok, view, _} = live(conn, "/admin/reading")
    view |> element("#item-#{item.id} button", "Edit") |> render_click()
    assert view |> element("button", "Cancel") |> render_click() =~ "Add an entry"
  end

  test "deletes an entry", %{conn: conn} do
    {:ok, item} = Reading.create_item(@entry)
    {:ok, view, _} = live(conn, "/admin/reading")
    assert view |> element("#item-#{item.id} button", "Delete") |> render_click() =~ "Deleted"
    assert Reading.list_items() == []
  end

  test "editing or deleting a missing entry says so", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin/reading")
    assert render_click(view, "edit", %{"id" => "999"}) =~ "no longer exists"
    assert render_click(view, "delete", %{"id" => "999"}) =~ "no longer exists"
  end
end
