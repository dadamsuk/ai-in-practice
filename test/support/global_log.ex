defmodule AiInPractice.GlobalLog do
  @moduledoc """
  Captures everything logged by any process while `fun` runs, formatted as
  the default handler would format it, at `level` (default `:debug`).

  `ExUnit.CaptureLog` sees only the calling processes; privacy tests need
  every process (sessions, their tasks, supervisors), so use this in
  `async: false` modules and give each test its own marker strings.
  """

  @doc false
  def log(event, %{config: %{collector: collector}}) do
    {formatter, formatter_config} = Logger.default_formatter(colors: [enabled: false])

    send(
      collector,
      {:global_log, IO.chardata_to_string(formatter.format(event, formatter_config))}
    )
  end

  def capture(level \\ :debug, fun) do
    id = :"global_log_#{System.unique_integer([:positive])}"
    previous = Logger.level()
    Logger.configure(level: level)
    :ok = :logger.add_handler(id, __MODULE__, %{level: level, config: %{collector: self()}})
    {:ok, %{level: default_level}} = :logger.get_handler_config(:default)
    :ok = :logger.update_handler_config(:default, :level, :none)

    try do
      fun.()
      Logger.flush()
      Process.sleep(50)
    after
      :logger.remove_handler(id)
      :logger.update_handler_config(:default, :level, default_level)
      Logger.configure(level: previous)
    end

    collect([])
  end

  defp collect(acc) do
    receive do
      {:global_log, line} -> collect([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join()
    end
  end
end
