defmodule TractorWeb.SafePush do
  @moduledoc """
  The single TractorWeb → `Phoenix.LiveView.push_event/3` boundary.

  Recursively sanitizes the event payload via `Tractor.JSON.sanitize_payload/2`
  before delegating to `Phoenix.LiveView.push_event/3`, so invalid UTF-8 in a
  nested map cannot fail the wire serialization that LiveView performs to
  reach the browser.

  Production code outside this module MUST NOT call
  `Phoenix.LiveView.push_event/3` directly. The CI gate added in phase B.3 of
  SPRINT-0015 enforces this.
  """

  @spec push_event(Phoenix.LiveView.Socket.t(), String.t(), map()) :: Phoenix.LiveView.Socket.t()
  def push_event(%Phoenix.LiveView.Socket{} = socket, event, payload) when is_map(payload) do
    Phoenix.LiveView.push_event(socket, event, Tractor.JSON.sanitize_payload(payload))
  end
end
