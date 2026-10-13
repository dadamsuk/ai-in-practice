defmodule AiInPractice.LogRedaction do
  @moduledoc """
  A primary `:logger` filter that keeps session data out of crash reports
  (PRD §10).

  When a process crashes, OTP logs its state, its last message and a
  stacktrace whose top frame carries the arguments of the failing call.
  For a session process or a LiveView those can hold a person's answers.
  `format_status/1` cannot reach the stacktrace, so this filter rewrites
  every OTP report before it is formatted:

    * stacktrace arguments become arities, wherever they appear;
    * a crashed server's `state` is replaced with `:redacted`;
    * strings in its last message, and in a crashed process's message
      queue and dictionary, become `:redacted`.

  Exception structs and module, function and line information are kept,
  so a crash can still be located.

  It must run before Elixir's `:logger_translator` filter, which turns the
  report into text, so `install/0` puts it first.
  """

  @doc "Installs the filter ahead of Elixir's translator. Safe to call twice."
  @spec install() :: :ok
  def install do
    %{filters: filters} = :logger.get_primary_config()

    # Set the whole list so the order is explicit: this filter first.
    others = Keyword.delete(filters, __MODULE__)

    :ok =
      :logger.set_primary_config(:filters, [{__MODULE__, {&__MODULE__.filter/2, []}} | others])

    :ok
  end

  @doc false
  def filter(%{msg: {:report, report}, meta: %{domain: [:otp | _]}} = event, _config) do
    %{event | msg: {:report, redact_report(report)}}
  rescue
    # A filter that raises is removed by :logger, so never raise; and never
    # let an unredacted report through.
    _ -> %{event | msg: {:string, "an OTP report was withheld: it could not be redacted"}}
  end

  def filter(_event, _config), do: :ignore

  # gen_server, gen_statem and gen_event termination reports.
  defp redact_report(%{label: {_behaviour, :terminate}} = report) do
    report
    |> Map.replace_lazy(:state, fn _ -> :redacted end)
    |> Map.replace_lazy(:last_message, &scrub/1)
    |> Map.replace_lazy(:queue, &scrub/1)
    |> Map.replace_lazy(:reason, &strip_stacks/1)
    |> Map.replace_lazy(:client_info, &strip_stacks/1)
  end

  # proc_lib crash reports (tasks and other special processes).
  defp redact_report(%{label: {:proc_lib, :crash}, report: [info | rest]} = report)
       when is_list(info) do
    info =
      Enum.map(info, fn
        {:error_info, error_info} -> {:error_info, strip_stacks(error_info)}
        {:messages, messages} -> {:messages, scrub(messages)}
        {:dictionary, dictionary} -> {:dictionary, scrub(dictionary)}
        other -> other
      end)

    %{report | report: [info | rest]}
  end

  defp redact_report(report), do: strip_stacks(report)

  @doc false
  # Replaces the argument list in every stacktrace entry with its arity.
  def strip_stacks({module, function, args, location})
      when is_atom(module) and is_atom(function) and is_list(args) and is_list(location),
      do: {module, function, length(args), location}

  def strip_stacks([head | tail]), do: [strip_stacks(head) | strip_stacks(tail)]

  def strip_stacks(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> strip_stacks() |> List.to_tuple()

  def strip_stacks(%{__struct__: _} = struct), do: struct
  def strip_stacks(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, strip_stacks(v)} end)
  def strip_stacks(other), do: other

  @doc false
  # Every string replaced, however deep.
  def scrub(binary) when is_binary(binary), do: :redacted
  def scrub([head | tail]), do: [scrub(head) | scrub(tail)]

  def scrub(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> scrub() |> List.to_tuple()

  def scrub(%{__struct__: module}), do: module
  def scrub(map) when is_map(map), do: Map.new(map, fn {k, v} -> {scrub(k), scrub(v)} end)
  def scrub(other), do: other
end
