defmodule Tractor.EventLog do
  @moduledoc """
  Append-only JSONL writer for a single node event stream.
  """

  use GenServer

  defstruct io: nil, seq: 0, last_event: nil

  @type t :: pid()

  @spec open(Path.t()) :: {:ok, t()} | {:error, term()}
  def open(node_dir) do
    GenServer.start_link(__MODULE__, node_dir)
  end

  @spec append(t(), atom() | String.t(), map()) :: :ok
  def append(log, kind, data) do
    GenServer.call(log, {:append, kind, data})
  end

  @spec close(t()) :: :ok
  def close(log) do
    GenServer.stop(log, :normal)
  end

  @impl true
  def init(node_dir) do
    File.mkdir_p!(node_dir)
    path = Path.join(node_dir, "events.jsonl")

    with {:ok, io} <- File.open(path, [:raw, :append, :binary]) do
      {:ok, %__MODULE__{io: io, seq: existing_seq(path)}}
    end
  end

  @impl true
  def handle_call({:append, kind, data}, _from, state) do
    seq = state.seq + 1

    event = %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "seq" => seq,
      "kind" => to_string(kind),
      "data" => data || %{}
    }

    :ok = :file.write(state.io, [Jason.encode_to_iodata!(event), "\n"])
    {:reply, :ok, %{state | seq: seq, last_event: event}}
  end

  @impl true
  def terminate(_reason, %{io: io}) do
    File.close(io)
    :ok
  end

  defp existing_seq(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.count()
    else
      0
    end
  end
end
