defmodule AiInPractice.Version.FrontMatter do
  @moduledoc false

  @doc "The `version` from a Markdown file's YAML front matter, or `\"unknown\"`."
  @spec version(String.t()) :: String.t()
  def version(text) do
    with [_, front] <- Regex.run(~r/\A---\n(.*?)\n---/s, text),
         [_, version] <- Regex.run(~r/^version:\s*"?([^"\n]+?)"?\s*$/m, front) do
      version
    else
      _ -> "unknown"
    end
  end
end

defmodule AiInPractice.Version do
  @moduledoc """
  The versions shown in every page footer and report footer, so the live
  site can be matched to the public repository (PRD §10, Transparency).

    * code version: the git SHA baked in at build time from `GIT_SHA`,
      falling back to `"dev"`
    * rubric version: the `version` in the front matter of `priv/rubric/rubric.md`
    * model: the OpenRouter model id configured for this release
  """

  @build_sha System.get_env("GIT_SHA")

  @doc "The code version: a short, lower-case git SHA, or `\"dev\"`."
  @spec code_version() :: String.t()
  def code_version do
    :ai_in_practice
    |> Application.get_env(:code_version, @build_sha)
    |> normalize_sha()
  end

  @doc false
  @spec normalize_sha(String.t() | nil) :: String.t()
  def normalize_sha(sha) when is_binary(sha) do
    sha = sha |> String.trim() |> String.downcase()

    if sha =~ ~r/\A[0-9a-f]{7,40}\z/ do
      String.slice(sha, 0, 12)
    else
      "dev"
    end
  end

  def normalize_sha(_), do: "dev"

  @doc "The rubric version from the rubric file's front matter."
  @spec rubric_version() :: String.t()
  defdelegate rubric_version, to: AiInPractice.Rubric, as: :version

  @doc "The model id used for this release."
  @spec model() :: String.t()
  def model, do: Application.fetch_env!(:ai_in_practice, :model)
end
