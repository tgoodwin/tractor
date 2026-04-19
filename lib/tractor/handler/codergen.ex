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

    node_dir = Path.join(run_dir, node.id)
    File.mkdir_p!(node_dir)
    Tractor.Paths.atomic_write!(Path.join(node_dir, "prompt.md"), prompt)
    stderr_log = Path.join(node_dir, "stderr.log")

    event_sink = fn %{kind: kind, data: data} ->
      Tractor.RunEvents.emit(Path.basename(run_dir), node.id, kind, data)
    end

    with {:ok, session} <-
           agent_client.start_session(adapter,
             cwd: run_dir,
             stderr_log: stderr_log,
             event_sink: event_sink
           ) do
      case agent_client.prompt(session, prompt, timeout) do
        {:ok, turn} ->
          :ok = agent_client.stop(session)
          response = response_text(turn)

          {:ok, response,
           %{
             prompt: prompt,
             response: response,
             status: status(node, turn),
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
      if is_binary(output) do
        String.replace(prompt, "{{#{node_id}}}", output)
      else
        prompt
      end
    end)
  end

  defp response_text(%Tractor.ACP.Turn{response_text: response}), do: response
  defp response_text(response) when is_binary(response), do: response

  defp status(node, %Tractor.ACP.Turn{token_usage: nil}) do
    %{"status" => "ok", "provider" => node.llm_provider}
  end

  defp status(node, %Tractor.ACP.Turn{token_usage: token_usage}) do
    %{"status" => "ok", "provider" => node.llm_provider, "token_usage" => token_usage}
  end

  defp status(node, _response) do
    %{"status" => "ok", "provider" => node.llm_provider}
  end
end
