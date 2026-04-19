defmodule Tractor.Paths do
  @moduledoc """
  Filesystem path helpers for Tractor run artifacts.
  """

  @spec data_dir(keyword()) :: Path.t()
  def data_dir(opts \\ []) do
    opts[:data_dir] ||
      System.get_env("TRACTOR_DATA_DIR") ||
      xdg_data_dir() ||
      Path.expand("~/.tractor")
  end

  @spec run_dir(keyword()) :: Path.t()
  def run_dir(opts \\ []) do
    opts
    |> runs_root()
    |> Path.join(Keyword.get(opts, :run_id, new_run_id()))
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

  defp runs_root(opts) do
    opts[:runs_dir] || Path.join(data_dir(opts), "runs")
  end

  defp xdg_data_dir do
    case System.get_env("XDG_DATA_HOME") do
      nil -> nil
      xdg -> Path.join(xdg, "tractor")
    end
  end

  defp new_run_id do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    short_id = Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)
    "#{timestamp}-#{short_id}"
  end
end
