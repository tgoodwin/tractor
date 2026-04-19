defmodule Tractor.Agent.Config do
  @moduledoc false

  def command(provider, default_command, default_args) do
    prefix = "TRACTOR_ACP_#{String.upcase(provider)}"

    {
      System.get_env("#{prefix}_COMMAND", default_command),
      args("#{prefix}_ARGS", default_args),
      env("#{prefix}_ENV_JSON")
    }
  end

  defp args(env_var, default_args) do
    case System.get_env(env_var) do
      nil -> default_args
      json -> Jason.decode!(json)
    end
  end

  defp env(env_var) do
    case System.get_env(env_var) do
      nil ->
        []

      json ->
        json
        |> Jason.decode!()
        |> Enum.map(fn {key, value} -> {key, to_string(value)} end)
        |> Enum.sort()
    end
  end
end
