defmodule TractorWeb.RunLive.StatusFeed do
  @moduledoc false

  use Phoenix.Component

  attr(:status_agent, :string, required: true)
  attr(:updates, :any, required: true)
  attr(:empty?, :boolean, required: true)

  def status_feed(assigns) do
    ~H"""
    <section class="status-feed-panel" aria-label="Status agent">
      <div class="runs-panel-header">
        <p class="eyebrow">Status</p>
      </div>
      <ol id="status-feed" class="status-feed" phx-update="stream">
        <li
          :for={{id, update} <- @updates}
          id={id}
          class="status-feed-row"
        >
          <div class="status-feed-row-top">
            <span class="status-feed-node mono">{update.node_id}</span>
            <span class="status-feed-iteration mono">x{update.iteration}</span>
            <span :if={update.timestamp} class="status-feed-time mono">{update.timestamp}</span>
          </div>
          <div class="status-feed-summary">{TractorWeb.Markdown.to_html(update.summary)}</div>
        </li>
        <li :if={@empty?} id="status-feed-empty" class="status-feed-empty">
          {empty_message(@status_agent)}
        </li>
      </ol>
    </section>
    """
  end

  defp empty_message("off"), do: "Status agent disabled"
  defp empty_message(_provider), do: "Waiting for first node..."
end
