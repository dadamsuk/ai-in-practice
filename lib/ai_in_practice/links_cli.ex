defmodule AiInPractice.LinksCLI do
  @moduledoc """
  The admin link commands, for use over SSH (PRD §11). They call the same
  `AiInPractice.Links` functions as the admin pages.

  In development: `mix links COMMAND ...`. On a release: `bin/links COMMAND
  ...`, which runs `rpc/1` inside the running node.

      recruiter --firm FIRM --contact NAME --email EMAIL [--quota N]
      individual --label LABEL [--quick]
      quota RECRUITER_ID N
      revoke recruiter RECRUITER_ID
      revoke link LINK_ID
      usage

  New links print their URL once: only a hash of the token is kept.
  `--quick` makes a quick individual link: three or four questions in
  about three minutes, for testing.
  """

  alias AiInPractice.Links
  alias AiInPracticeWeb.{LinkFormat, LinkURLs}

  @usage """
  usage:
    links recruiter --firm FIRM --contact NAME --email EMAIL [--quota N]
    links individual --label LABEL [--quick]
    links quota RECRUITER_ID N
    links revoke recruiter RECRUITER_ID
    links revoke link LINK_ID
    links usage
  """

  @doc "Runs a command. Returns `{:ok, output}` or `{:error, message}`."
  @spec run([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def run(["recruiter" | args]) do
    with {:ok, opts} <-
           parse(args, firm: :string, contact: :string, email: :string, quota: :string) do
      attrs = %{
        firm_name: opts[:firm],
        contact_name: opts[:contact],
        contact_email: opts[:email],
        quota: opts[:quota] || 10
      }

      case Links.create_recruiter_link(attrs) do
        {:ok, link, token} ->
          {:ok,
           """
           recruiter link #{link.id} for #{link.firm_name}, quota #{link.quota}
           #{LinkURLs.recruiter_url(token)}
           copy it now: it is shown only once.
           """}

        {:error, changeset} ->
          {:error, errors(changeset)}
      end
    end
  end

  def run(["individual" | args]) do
    with {:ok, opts} <- parse(args, label: :string, quick: :boolean) do
      case Links.create_individual_link(%{label: opts[:label], quick: opts[:quick] || false}) do
        {:ok, link, token} ->
          {:ok,
           """
           individual link #{link.id} #{link.label}#{if link.quick, do: " (quick)"}
           #{LinkURLs.assessment_url(token)}
           copy it now: it is shown only once.
           """}

        {:error, changeset} ->
          {:error, errors(changeset)}
      end
    end
  end

  def run(["quota", id, quota]) do
    with {:ok, recruiter} <- fetch(:recruiter, id) do
      case Links.set_quota(recruiter, quota) do
        {:ok, r} -> {:ok, "quota for #{r.firm_name} is now #{r.quota}\n"}
        {:error, changeset} -> {:error, errors(changeset)}
      end
    end
  end

  def run(["revoke", "recruiter", id]) do
    with {:ok, recruiter} <- fetch(:recruiter, id),
         {:ok, r} <- revoked(Links.revoke_recruiter_link(recruiter)) do
      {:ok, "revoked recruiter link #{r.id} for #{r.firm_name}\n"}
    end
  end

  def run(["revoke", "link", id]) do
    with {:ok, link} <- fetch(:link, id),
         {:ok, l} <- revoked(Links.revoke_assessment_link(link)) do
      {:ok, "revoked link #{l.id}\n"}
    end
  end

  def run(["usage"]), do: {:ok, usage_table(Links.usage())}

  def run(_), do: {:error, @usage}

  @doc """
  The release entry point, called by `bin/links` through `rpc`. Each
  argument arrives base64-encoded so that no quoting can break out of the
  expression.
  """
  @spec rpc(String.t()) :: :ok
  def rpc(encoded) do
    args = encoded |> String.split(" ", trim: true) |> Enum.map(&Base.decode64!/1)

    case run(args) do
      {:ok, out} -> IO.write(out)
      {:error, message} -> IO.write("error: " <> message)
    end
  end

  defp parse(args, switches) do
    case OptionParser.parse(args, strict: switches) do
      {opts, [], []} -> {:ok, opts}
      _ -> {:error, @usage}
    end
  end

  defp fetch(kind, id) do
    found =
      case {kind, Integer.parse(id)} do
        {:recruiter, {n, ""}} -> Links.get_recruiter_link(n)
        {:link, {n, ""}} -> Links.get_assessment_link(n)
        _ -> nil
      end

    if found, do: {:ok, found}, else: {:error, "no #{kind} link with id #{id}\n"}
  end

  defp revoked({:ok, link}), do: {:ok, link}
  defp revoked({:error, :already_revoked}), do: {:error, "that link is already revoked\n"}

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}\n" end)
  end

  defp usage_table(%{recruiters: recruiters, individuals: individuals}) do
    recruiter_rows =
      for r <- recruiters do
        [
          "#{r.link.id}",
          r.link.firm_name,
          "#{r.minted}",
          "#{r.started}",
          "#{r.completed}",
          "#{r.abandoned}",
          "#{r.quota_used}/#{r.link.quota}",
          if(r.link.revoked_at, do: "revoked", else: "open")
        ]
      end

    individual_rows =
      for i <- individuals do
        [
          "#{i.link.id}",
          i.link.label,
          if(i.link.quick, do: "quick", else: "full"),
          LinkFormat.state(i.state),
          LinkFormat.datetime(i.link.inserted_at)
        ]
      end

    [
      "recruiter links\n",
      columns(
        ["id", "firm", "minted", "started", "completed", "abandoned", "quota", "status"],
        recruiter_rows
      ),
      "\nindividual links\n",
      columns(["id", "label", "length", "status", "created"], individual_rows)
    ]
    |> IO.iodata_to_binary()
  end

  defp columns(header, rows) do
    widths =
      [header | rows]
      |> Enum.zip_with(fn cells -> cells |> Enum.map(&String.length/1) |> Enum.max() end)

    for row <- [header | rows] do
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, w} -> String.pad_trailing(cell, w) end)
      |> String.trim_trailing()
      |> Kernel.<>("\n")
    end
  end
end
