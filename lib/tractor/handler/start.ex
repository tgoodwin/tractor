defmodule Tractor.Handler.Start do
  @moduledoc """
  No-op start handler.
  """

  @behaviour Tractor.Handler

  @impl Tractor.Handler
  def run(_node, _context, _run_dir) do
    {:ok, "", %{status: %{"status" => "ok"}}}
  end
end
