defmodule Tractor.Handler.Conditional do
  @moduledoc """
  No-op handler used for pure routing fork nodes.
  """

  @behaviour Tractor.Handler

  @impl Tractor.Handler
  def run(_node, _context, _run_dir) do
    {:ok, %{}, %{status: %{"status" => "ok"}}}
  end
end
