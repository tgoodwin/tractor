defmodule Tractor.Agent.Config do
  @moduledoc false

  # Resolves a provider's bridge command + args + env from three sources,
  # highest precedence first:
  #   1. TRACTOR_ACP_<PROVIDER>_{COMMAND,ARGS,ENV_JSON} env vars
  #   2. .tractor/config.toml  [agents.<provider>] { command, args, env }
  #   3. Adapter defaults
  def command(provider, default_command, default_args) do
    prefix = "TRACTOR_ACP_#{String.upcase(provider)}"
    config = Tractor.Config.get([:agents, provider], %{})

    {
      resolve_command(prefix, config, default_command),
      resolve_args(prefix, config, default_args),
      resolve_env(prefix, config)
    }
  end

  defp resolve_command(prefix, config, default) do
    System.get_env("#{prefix}_COMMAND") || Map.get(config, "command") || default
  end

  defp resolve_args(prefix, config, default) do
    case System.get_env("#{prefix}_ARGS") do
      nil ->
        case Map.get(config, "args") do
          nil -> default
          list when is_list(list) -> list
        end

      json ->
        Jason.decode!(json)
    end
  end

  defp resolve_env(prefix, config) do
    env_var = "#{prefix}_ENV_JSON"

    case System.get_env(env_var) do
      nil -> config |> Map.get("env", %{}) |> normalize_env()
      json -> json |> Jason.decode!() |> normalize_env()
    end
  end

  defp normalize_env(map) when is_map(map) do
    map
    |> Enum.map(fn
      {key, false} -> {to_string(key), false}
      {key, nil} -> {to_string(key), false}
      {key, value} -> {to_string(key), to_string(value)}
    end)
    |> Enum.sort()
  end

  defp normalize_env(_), do: []
end
