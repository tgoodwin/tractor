defmodule TractorWeb.RunLive.Show do
  @moduledoc false

  use Phoenix.LiveView

  embed_templates "../templates/run_live/*"

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    {:ok, assign(socket, run_id: run_id, node_states: %{}, selected_node_id: nil)}
  end

  @impl true
  def render(assigns), do: show(assigns)
end
