defmodule TractorWeb.RunLive.Index do
  @moduledoc """
  Landing page: lists every run discoverable in `Tractor.Paths.runs_dir/0`.
  Click a row to jump to its detail view at `/runs/:run_id`.
  """

  use Phoenix.LiveView

  alias TractorWeb.RunIndex

  @refresh_ms 5_000

  embed_templates("../templates/run_live/index*")

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok,
     assign(socket,
       runs: load_runs(),
       runs_dir: Tractor.Paths.runs_dir()
     )}
  end

  @impl true
  def render(assigns), do: index(assigns)

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, :runs, load_runs())}
  end

  defp load_runs, do: RunIndex.list(Tractor.Paths.runs_dir())

  defp run_status_label(%{status: status}), do: RunIndex.status_label(status)

  defp run_started_at(%{started_at: nil}), do: "—"

  defp run_started_at(%{started_at: %DateTime{} = dt}) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  defp run_started_at_iso(%{started_at: %DateTime{} = dt}), do: DateTime.to_iso8601(dt)
  defp run_started_at_iso(_entry), do: nil

  defp run_duration(entry), do: RunIndex.duration_label(entry)

  defp tractor_version do
    case Application.spec(:tractor, :vsn) do
      nil -> ""
      vsn -> "v#{List.to_string(vsn)}"
    end
  end
end
