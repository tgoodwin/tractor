defmodule Tractor.Paths do
  @moduledoc """
  Filesystem path helpers for Tractor run artifacts.
  """

  @spec data_dir(keyword()) :: Path.t()
  def data_dir(opts \\ []) do
    opts[:data_dir] ||
      System.get_env("TRACTOR_DATA_DIR") ||
      project_data_dir() ||
      xdg_data_dir() ||
      Path.expand("~/.tractor")
  end

  @spec runs_dir(keyword()) :: Path.t()
  def runs_dir(opts \\ []) do
    opts[:runs_dir] ||
      Application.get_env(:tractor, :runs_dir) ||
      Path.join(data_dir(opts), "runs")
      |> Path.expand()
  end

  # If the CWD looks like a Tractor context (has a .tractor/ dir already, or
  # has a DOT file next to a Mix project), default to ./.tractor. Lets a user
  # keep run artifacts inside the project for sharing / inspection without
  # polluting their home directory.
  defp project_data_dir do
    cwd = File.cwd!()
    local = Path.join(cwd, ".tractor")

    cond do
      File.dir?(local) -> local
      File.exists?(Path.join(cwd, "mix.exs")) -> local
      true -> nil
    end
  end

  @spec run_dir(keyword()) :: Path.t()
  def run_dir(opts \\ []) do
    Path.join(runs_dir(opts), Keyword.get(opts, :run_id) || new_run_id())
  end

  @spec atomic_write!(Path.t(), iodata()) :: :ok
  def atomic_write!(path, contents) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    tmp_path = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    File.open!(tmp_path, [:write, :binary], fn file ->
      IO.binwrite(file, contents)
      :ok = :file.sync(file)
    end)

    File.rename!(tmp_path, path)
    :ok
  end

  @spec checkpoint_path(Path.t()) :: Path.t()
  def checkpoint_path(run_dir) do
    Path.join(run_dir, "checkpoint.json")
  end

  defp xdg_data_dir do
    case System.get_env("XDG_DATA_HOME") do
      nil -> nil
      xdg -> Path.join(xdg, "tractor")
    end
  end

  @doc """
  Build a short slug run id deterministically derived from `dt` (UTC microsecond
  precision). Used as both the URL-visible run id and the run-directory name.
  """
  @spec new_run_id(DateTime.t()) :: String.t()
  def new_run_id(dt \\ DateTime.utc_now()) do
    dt = DateTime.shift_zone!(dt, "Etc/UTC")
    iso = DateTime.to_iso8601(dt)
    <<slug_bytes::4-bytes, _::binary>> = :crypto.hash(:sha256, iso)
    Base.url_encode64(slug_bytes, padding: false)
  end
end
