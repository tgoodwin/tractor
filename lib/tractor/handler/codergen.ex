defmodule Tractor.Handler.Codergen do
  @moduledoc """
  Codergen handler that prompts the configured ACP provider.
  """

  @behaviour Tractor.Handler

  alias Tractor.Node

  @default_timeout 300_000

  @provider_modules %{
    "claude" => Tractor.Agent.Claude,
    "codex" => Tractor.Agent.Codex,
    "gemini" => Tractor.Agent.Gemini
  }

  @impl Tractor.Handler
  def run(%Node{} = node, context, run_dir) do
    agent_client = Application.get_env(:tractor, :agent_client, Tractor.ACP.Session)
    adapter = Map.fetch!(@provider_modules, node.llm_provider)
    {command, args, env} = adapter.command([])
    prompt = interpolate(node.prompt || "", context)
    timeout = node.timeout || @default_timeout

    with {:ok, session} <- agent_client.start_session(adapter, cwd: run_dir) do
      case agent_client.prompt(session, prompt, timeout) do
        {:ok, response} ->
          :ok = agent_client.stop(session)

          {:ok, response,
           %{
             prompt: prompt,
             response: response,
             status: %{"status" => "ok", "provider" => node.llm_provider},
             provider_command: %{
               provider: node.llm_provider,
               command: command,
               args: args,
               env: env
             }
           }}

        {:error, reason} ->
          :ok = agent_client.stop(session)
          {:error, reason}
      end
    end
  end

  defp interpolate(prompt, context) do
    Enum.reduce(context, prompt, fn {node_id, output}, prompt ->
      String.replace(prompt, "{{#{node_id}}}", output)
    end)
  end
end
