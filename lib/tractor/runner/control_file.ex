defmodule Tractor.Runner.ControlFile do
  @moduledoc false

  alias Tractor.Checkpoint

  @spec control_dir(Path.t()) :: Path.t()
  def control_dir(run_dir), do: Path.join(run_dir, "control")

  @spec path(Path.t(), String.t()) :: Path.t()
  def path(run_dir, node_id), do: Path.join(control_dir(run_dir), "wait-#{node_id}.json")

  @spec scan(Path.t()) :: [Path.t()]
  def scan(run_dir) do
    run_dir
    |> control_dir()
    |> Path.join("wait-*.json")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @spec write(Path.t(), String.t(), String.t(), String.t(), keyword()) :: :ok
  def write(run_dir, run_id, node_id, label, opts \\ []) do
    case current_wait(run_dir, node_id) do
      %{"attempt" => attempt} ->
        payload = %{
          "run_id" => run_id,
          "node_id" => node_id,
          "attempt" => attempt,
          "label" => label,
          "submitted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "submitted_by" => Keyword.get(opts, :submitted_by, "observer")
        }

        write_atomic_json(path(run_dir, node_id), payload)

      _other ->
        :ok
    end
  end

  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw) do
      {:ok, json}
    end
  end

  @spec archive_stale(Path.t()) :: :ok
  def archive_stale(path) do
    stale_path =
      path <>
        ".stale-" <>
        (DateTime.utc_now() |> DateTime.to_unix(:millisecond) |> Integer.to_string())

    File.rename(path, stale_path)
    :ok
  end

  defp current_wait(run_dir, node_id) do
    with {:ok, checkpoint} <- Checkpoint.read(run_dir),
         entry when is_map(entry) <- get_in(checkpoint, ["waiting", node_id]) do
      entry
    else
      _other -> nil
    end
  end

  defp write_atomic_json(path, payload) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(payload, pretty: true))
    File.rename!(tmp, path)
    :ok
  end
end
