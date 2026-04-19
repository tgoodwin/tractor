defmodule Tractor.RunStore do
  @moduledoc """
  Persists run manifests and per-node artifacts.
  """

  alias Tractor.{Paths, Pipeline}

  @type t :: %__MODULE__{
          run_id: String.t(),
          run_dir: Path.t(),
          manifest: map()
        }

  defstruct run_id: nil,
            run_dir: nil,
            manifest: %{}

  @spec open(Pipeline.t(), keyword()) :: {:ok, t()}
  def open(%Pipeline{} = pipeline, opts \\ []) do
    run_dir = Paths.run_dir(opts)
    File.mkdir_p!(run_dir)

    manifest = %{
      "run_id" => Path.basename(run_dir),
      "pipeline_path" => pipeline.path,
      "goal" => pipeline.goal,
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "tractor_version" => tractor_version(),
      "status" => "running",
      "provider_commands" => []
    }

    store = %__MODULE__{run_id: manifest["run_id"], run_dir: run_dir, manifest: manifest}
    write_manifest(store, manifest)
    Tractor.RunEvents.register_run(store.run_id, store.run_dir)

    {:ok, store}
  end

  @spec write_node(t(), String.t(), map()) :: :ok
  def write_node(%__MODULE__{} = store, node_id, artifact) do
    node_dir = Path.join(store.run_dir, node_id)
    File.mkdir_p!(node_dir)

    if Map.has_key?(artifact, :prompt) do
      Paths.atomic_write!(Path.join(node_dir, "prompt.md"), artifact.prompt || "")
    end

    if Map.has_key?(artifact, :response) do
      Paths.atomic_write!(Path.join(node_dir, "response.md"), artifact.response || "")
    end

    if Map.has_key?(artifact, :status) do
      Paths.atomic_write!(Path.join(node_dir, "status.json"), encode_json!(artifact.status))
    end

    :ok
  end

  @spec mark_node_pending(t(), String.t()) :: :ok
  def mark_node_pending(%__MODULE__{} = store, node_id) do
    write_status(store, node_id, %{"status" => "pending"})
  end

  @spec mark_node_running(t(), String.t(), DateTime.t() | String.t()) :: :ok
  def mark_node_running(%__MODULE__{} = store, node_id, started_at) do
    write_status(store, node_id, %{
      "status" => "running",
      "started_at" => timestamp(started_at)
    })
  end

  @spec mark_node_succeeded(t(), String.t(), map()) :: :ok
  def mark_node_succeeded(%__MODULE__{} = store, node_id, outcome_meta) do
    write_status(
      store,
      node_id,
      Map.merge(%{"status" => "ok", "finished_at" => timestamp(DateTime.utc_now())}, outcome_meta)
    )
  end

  @spec mark_node_failed(t(), String.t(), term()) :: :ok
  def mark_node_failed(%__MODULE__{} = store, node_id, reason) do
    write_status(store, node_id, %{
      "status" => "error",
      "reason" => inspect(reason),
      "finished_at" => timestamp(DateTime.utc_now())
    })
  end

  @spec finalize(t(), map()) :: :ok
  def finalize(%__MODULE__{} = store, attrs) do
    manifest =
      store.manifest
      |> Map.merge(%{
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "status" => Map.fetch!(attrs, :status),
        "provider_commands" => redact_provider_commands(Map.get(attrs, :provider_commands, []))
      })

    write_manifest(store, manifest)
  end

  defp write_manifest(store, manifest) do
    Paths.atomic_write!(Path.join(store.run_dir, "manifest.json"), encode_json!(manifest))
  end

  defp write_status(store, node_id, status) do
    node_dir = Path.join(store.run_dir, node_id)
    File.mkdir_p!(node_dir)
    Paths.atomic_write!(Path.join(node_dir, "status.json"), encode_json!(status))
  end

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(timestamp) when is_binary(timestamp), do: timestamp

  defp encode_json!(data) do
    Jason.encode_to_iodata!(data, pretty: true)
  end

  defp redact_provider_commands(commands) do
    Enum.map(commands, fn command ->
      %{
        "provider" => string_key(command, :provider),
        "command" => string_key(command, :command),
        "args" => Map.get(command, :args, []),
        "env" => redact_env(Map.get(command, :env, []))
      }
    end)
  end

  defp string_key(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp redact_env(env) when is_list(env) do
    Map.new(env, fn {key, _value} -> {key, "[REDACTED]"} end)
  end

  defp redact_env(env) when is_map(env) do
    Map.new(env, fn {key, _value} -> {key, "[REDACTED]"} end)
  end

  defp tractor_version do
    case Application.spec(:tractor, :vsn) do
      nil -> "0.1.0"
      version -> to_string(version)
    end
  end
end
