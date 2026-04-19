defmodule Tractor.Handler.Exit do
  @moduledoc """
  No-op exit handler.
  """

  @behaviour Tractor.Handler

  @impl Tractor.Handler
  def run(_node, _context, _run_dir) do
    {:ok, "", %{status: %{"status" => "ok"}}}
  end
end
