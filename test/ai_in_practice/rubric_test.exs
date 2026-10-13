defmodule AiInPractice.RubricTest do
  use ExUnit.Case, async: true

  alias AiInPractice.Reading.Item
  alias AiInPractice.{RoleGroups, Rubric, Version}
  alias AiInPractice.Version.FrontMatter

  test "the version comes from the rubric file's front matter and reaches Version" do
    assert Rubric.version() == "priv/rubric/rubric.md" |> File.read!() |> FrontMatter.version()
    assert Rubric.version() == "0.2"
    assert Version.rubric_version() == Rubric.version()
  end

  test "sections are read by heading, in order, without the front matter" do
    headings = Enum.map(Rubric.sections(), &elem(&1, 0))
    assert hd(headings) == "Purpose"
    assert "Area 5: Attitude" in headings
    refute Enum.any?(Rubric.sections(), fn {_, body} -> body =~ "source: \"Slipdock" end)
    assert Rubric.section!("Principles") =~ "Evidence is a specific instance"
  end

  test "an unknown section raises" do
    assert_raise ArgumentError, ~r/no section "Nope"/, fn -> Rubric.section!("Nope") end
  end

  test "areas match the reading list's areas and parse from their ids" do
    assert Rubric.areas() == Item.areas()
    assert Rubric.parse_area("leading_adoption") == {:ok, :leading_adoption}
    assert Rubric.parse_area("leadership") == :error
    assert Rubric.parse_area(:attitude) == :error
    assert Rubric.area_name(:applying_to_business) == "Applying AI to the business"
  end

  describe "role_calibration/1" do
    test "every role group has its own row of the table" do
      for group <- RoleGroups.all() do
        calibration = Rubric.role_calibration(group)
        assert calibration =~ "Role group: #{Rubric.role_label(group)}."

        for other <- RoleGroups.all(), other != group do
          refute calibration =~ "Role group: #{Rubric.role_label(other)}."
        end
      end
    end

    test "carries the table's depth and emphasis" do
      assert Rubric.role_calibration(:finance) =~ "Depth expected: Business cases and controls."
      assert Rubric.role_calibration(:finance) =~ "controls on AI-driven processes"
    end

    test "request depth: mechanism for technology, management questions for boards, outcome for the rest" do
      assert Rubric.role_calibration(:technology_product) =~ "asked for mechanism"
      refute Rubric.role_calibration(:technology_product) =~ "Board members are asked"
      assert Rubric.role_calibration(:board_ned) =~ "Board members are asked for the question"
      refute Rubric.role_calibration(:board_ned) =~ "mechanism"

      for group <- RoleGroups.all() -- [:technology_product, :board_ned] do
        assert Rubric.role_calibration(group) =~ "asked for outcome and how they knew"
        refute Rubric.role_calibration(group) =~ "mechanism"
      end
    end

    test "the Director/CxO note applies to everyone except board members" do
      refute Rubric.role_calibration(:board_ned) =~ "Director vs CxO"
      assert Rubric.role_calibration(:people) =~ "Director vs CxO"
    end
  end

  describe "area_section/2" do
    test "keeps role-marked guidance questions only for that role, without the marker" do
      tech = Rubric.area_section(:understanding, :technology_product)
      assert tech =~ "- How they decided something in production was good enough"
      refute tech =~ "*(Technology and product)*"

      refute Rubric.area_section(:understanding, :finance) =~ "in production was good enough"
      assert Rubric.area_section(:understanding, :finance) =~ "A time an AI tool gave them"

      assert Rubric.area_section(:applying_to_business, :board_ned) =~
               "most useful question they have put to management"

      refute Rubric.area_section(:applying_to_business, :ceo_gm) =~ "put to management"
    end

    test "keeps board-only role notes for board members only, and general ones for all" do
      assert Rubric.area_section(:leading_adoption, :board_ned) =~
               "for board members, this covers"

      refute Rubric.area_section(:leading_adoption, :operations) =~ "for board members"
      assert Rubric.area_section(:personal_use, :operations) =~ "board members and some CxOs"
    end
  end
end
