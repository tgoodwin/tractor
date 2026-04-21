defmodule TractorWeb.RunLive.WaitForm do
  @moduledoc false

  use Phoenix.Component

  alias TractorWeb.Format

  attr(:node_id, :string, required: true)
  attr(:status, :map, required: true)
  attr(:error, :string, default: nil)

  def wait_form(assigns) do
    assigns =
      assigns
      |> assign(:wait_prompt, Map.get(assigns.status, "wait_prompt") || "Choose the next edge")
      |> assign(:outgoing_labels, Map.get(assigns.status, "outgoing_labels", []))
      |> assign(:waiting_since, parse_time(Map.get(assigns.status, "waiting_since")))
      |> assign(:remaining_ms, remaining_ms(assigns.status))

    ~H"""
    <section class="wait-form-panel" aria-label="Human decision required">
      <div class="panel-section-heading">
        <p class="eyebrow">Decision Required</p>
      </div>

      <div class="wait-form-body">
        <p class="wait-form-prompt">{@wait_prompt}</p>

        <div class="wait-form-meta mono">
          <span :if={@waiting_since}>waiting {elapsed_label(@waiting_since)}</span>
          <span :if={!is_nil(@remaining_ms)}>timeout in {Format.duration_ms(@remaining_ms)}</span>
        </div>

        <p :if={@error} class="wait-form-error">{@error}</p>

        <div class="wait-form-actions">
          <button
            :for={label <- @outgoing_labels}
            type="button"
            class="wait-choice-button"
            phx-click="submit_wait_choice"
            phx-value-label={label}
          >
            {label}
          </button>
        </div>
      </div>
    </section>
    """
  end

  defp remaining_ms(status) do
    with wait_timeout_ms when is_integer(wait_timeout_ms) <- status["wait_timeout_ms"],
         %DateTime{} = waiting_since <- parse_time(status["waiting_since"]) do
      elapsed_ms = max(DateTime.diff(DateTime.utc_now(), waiting_since, :millisecond), 0)
      max(wait_timeout_ms - elapsed_ms, 0)
    else
      _other -> nil
    end
  end

  defp elapsed_label(%DateTime{} = waiting_since) do
    waiting_since
    |> DateTime.diff(DateTime.utc_now(), :millisecond)
    |> abs()
    |> Format.duration_ms()
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end
end
