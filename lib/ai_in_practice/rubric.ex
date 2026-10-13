defmodule AiInPractice.Rubric do
  @moduledoc """
  The rubric (wiki W-106), read at compile time from `priv/rubric/rubric.md`
  so the public repository carries exactly the text the prompts are built
  from. Its front matter `version` is the rubric version shown in every
  footer (`AiInPractice.Version`).

  Sections are addressed by their `## ` heading. The role-specific parts
  (a role group's row of the calibration table, its request depth, and
  guidance questions or role notes marked for one role) are filtered so
  each prompt carries its own group's calibration and no other group's.
  """

  alias AiInPractice.Version.FrontMatter

  @path Path.expand("../../priv/rubric/rubric.md", __DIR__)
  @external_resource @path

  @text File.read!(@path)
  @version FrontMatter.version(@text)

  @sections @text
            |> String.replace(~r/\A---\n.*?\n---\n/s, "")
            |> String.split(~r/^## /m)
            |> tl()
            |> Enum.map(fn chunk ->
              [title, body] = String.split(chunk, "\n", parts: 2)
              {String.trim(title), String.trim(body)}
            end)

  @areas [
    understanding: "Understanding",
    personal_use: "Personal use",
    applying_to_business: "Applying AI to the business",
    leading_adoption: "Leading adoption",
    attitude: "Attitude"
  ]

  # The label each role group has in the rubric's calibration table and in
  # role-marked guidance questions.
  @role_labels %{
    ceo_gm: "CEO / GM",
    finance: "Finance (CFO)",
    operations: "Operations (COO)",
    commercial: "Commercial (sales, marketing)",
    people: "People (HR)",
    technology_product: "Technology and product (CTO, CPO)",
    board_ned: "Board / NED"
  }

  # Guidance-question markers, e.g. "*(Board / NED)*".
  @marker_groups %{"Technology and product" => :technology_product, "Board / NED" => :board_ned}

  @type area ::
          :understanding | :personal_use | :applying_to_business | :leading_adoption | :attitude

  @doc "The rubric version from the file's front matter."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Every `## ` section as `{heading, body}`, in order."
  @spec sections() :: [{String.t(), String.t()}]
  def sections, do: @sections

  @doc "The body of the section with this heading. Raises if there is none."
  @spec section!(String.t()) :: String.t()
  def section!(heading) do
    case List.keyfind(@sections, heading, 0) do
      {_, body} -> body
      nil -> raise ArgumentError, "the rubric has no section #{inspect(heading)}"
    end
  end

  @doc "The five areas, in rubric order."
  @spec areas() :: [area()]
  def areas, do: Keyword.keys(@areas)

  @doc "An area's readable name."
  @spec area_name(area()) :: String.t()
  def area_name(area), do: Keyword.fetch!(@areas, area)

  @doc "Parses an area from its string id, refusing anything unknown."
  @spec parse_area(term()) :: {:ok, area()} | :error
  def parse_area(value) when is_binary(value) do
    case Enum.find(areas(), &(Atom.to_string(&1) == value)) do
      nil -> :error
      area -> {:ok, area}
    end
  end

  def parse_area(_), do: :error

  @doc "The label a role group has in the rubric's calibration table."
  @spec role_label(AiInPractice.RoleGroups.t()) :: String.t()
  def role_label(group), do: Map.fetch!(@role_labels, group)

  @doc """
  An area's section, filtered for `group`: guidance questions and role
  notes marked for another role are removed, and the marker is dropped
  from those that apply.
  """
  @spec area_section(area(), AiInPractice.RoleGroups.t()) :: String.t()
  def area_section(area, group) do
    index = Enum.find_index(areas(), &(&1 == area)) + 1

    "Area #{index}: #{area_name(area)}"
    |> section!()
    |> String.split("\n")
    |> Enum.flat_map(&filter_line(&1, group))
    |> Enum.join("\n")
  end

  defp filter_line(line, group) do
    case Regex.run(~r/^- \*\((.+?)\)\* (.*)$/, line) do
      [_, marker, rest] ->
        if Map.fetch!(@marker_groups, marker) == group, do: ["- " <> rest], else: []

      nil ->
        if String.starts_with?(line, "**Role notes:** for board members") and group != :board_ned,
          do: [],
          else: [line]
    end
  end

  @doc """
  The role calibration for `group`: what the table says about this group,
  the Director/CxO note (not for board members), and the request depth
  that applies to it.
  """
  @spec role_calibration(AiInPractice.RoleGroups.t()) :: String.t()
  def role_calibration(group) do
    body = section!("Role calibration")
    label = role_label(group)

    [_, depth, emphasis] =
      Regex.run(~r/^\| #{Regex.escape(label)} \| (.+?) \| (.+?) \|$/m, body) ||
        raise ArgumentError, "the rubric has no calibration row for #{label}"

    [director] = Regex.run(~r/^\*\*Director vs CxO:\*\*.*$/m, body)

    [
      "Role group: #{label}.",
      "Depth expected: #{depth}.",
      "Where the emphasis falls: #{emphasis}.",
      if(group != :board_ned, do: director),
      "**Request depth:** " <> request_depth(group)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # The rubric's request-depth paragraph has one sentence for technology
  # and product, one for board members and one for everyone else.
  defp request_depth(group) do
    [_, paragraph] =
      Regex.run(~r/^\*\*Request depth by role:\*\* (.*)$/m, section!("Role calibration"))

    [tech, board, others] = String.split(paragraph, ~r/(?<=\.) /)

    case group do
      :technology_product -> tech
      :board_ned -> board
      _ -> others
    end
  end
end
