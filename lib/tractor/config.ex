defmodule Tractor.Config do
  @moduledoc """
  Loads per-project Tractor configuration from `.tractor/config.toml`.

  Precedence for a given value (e.g. the Claude bridge command):
    1. TRACTOR_* env var (set at runtime)
    2. `.tractor/config.toml` in the resolved data dir's parent
    3. Adapter default

  The file is entirely optional; missing file is silently ignored.
  Malformed TOML raises at startup so the user sees the problem.
  """

  @doc """
  Load the config map (cached in the :persistent_term table keyed on the path).
  Returns `%{}` if no file is present.
  """
  @spec load(keyword()) :: map()
  def load(opts \\ []) do
    path = config_path(opts)

    case :persistent_term.get({__MODULE__, path}, :miss) do
      :miss ->
        config = read(path)
        :persistent_term.put({__MODULE__, path}, config)
        config

      cached ->
        cached
    end
  end

  @doc "Clear the cached config. Tests call this between runs."
  @spec reset() :: :ok
  def reset do
    :persistent_term.get()
    |> Enum.each(fn
      {{__MODULE__, _path}, _value} = entry ->
        :persistent_term.erase(elem(entry, 0))

      _other ->
        :ok
    end)

    :ok
  end

  @doc """
  Look up a value at a key path in the loaded config.
  Example: `Tractor.Config.get([:agents, :claude, :command])`.
  """
  @spec get([atom() | String.t()], term(), keyword()) :: term()
  def get(key_path, default \\ nil, opts \\ []) do
    opts
    |> load()
    |> get_in(Enum.map(key_path, &to_string/1))
    |> case do
      nil -> default
      value -> value
    end
  end

  defp config_path(opts) do
    cond do
      path = Keyword.get(opts, :config_path) -> path
      path = Application.get_env(:tractor, :config_path) -> path
      true -> default_config_path()
    end
  end

  defp default_config_path do
    data_dir = Tractor.Paths.data_dir([])
    Path.join(data_dir, "config.toml")
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Toml.decode(contents) do
          {:ok, map} ->
            map

          {:error, reason} ->
            raise "invalid TOML in #{path}: #{inspect(reason)}"
        end

      {:error, _} ->
        %{}
    end
  end
end
