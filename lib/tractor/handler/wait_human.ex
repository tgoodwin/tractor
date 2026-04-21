defmodule Tractor.Handler.WaitHuman do
  @moduledoc """
  Suspends execution until an operator or timeout resolves the node.
  """

  @behaviour Tractor.Handler

  alias Tractor.Context.Template
  alias Tractor.{Node, Paths}

  @impl Tractor.Handler
  def run(%Node{} = node, context, run_dir) do
    payload = %{
      wait_prompt:
        case Node.wait_prompt(node) do
          nil -> nil
          prompt -> Template.render(prompt, context)
        end,
      outgoing_labels: Node.outgoing_labels(node, Map.fetch!(context, "__pipeline__")),
      wait_timeout_ms: Node.wait_timeout_ms(node),
      default_edge: Node.default_edge(node)
    }

    attempt = context["__attempt__"] || 1
    path = Path.join([run_dir, node.id, "attempt-#{attempt}", "wait.json"])

    Paths.atomic_write!(path, Jason.encode_to_iodata!(payload, pretty: true))

    {:wait, %{kind: :wait_human, payload: payload}}
  end
end
