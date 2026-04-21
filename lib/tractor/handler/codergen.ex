defmodule Tractor.Handler.Codergen do
  @moduledoc """
  Codergen handler that prompts the configured ACP provider.
  """

  @behaviour Tractor.Handler

  alias Tractor.Context.Template
  alias Tractor.Node

  @default_timeout 600_000

  @provider_modules %{
    "claude" => Tractor.Agent.Claude,
    "codex" => Tractor.Agent.Codex,
    "gemini" => Tractor.Agent.Gemini
  }

  @impl Tractor.Handler
  def default_timeout_ms, do: @default_timeout

  @impl Tractor.Handler
  def run(%Node{} = node, context, run_dir) do
    agent_client = Application.get_env(:tractor, :agent_client, Tractor.ACP.Session)
    adapter = Map.fetch!(@provider_modules, node.llm_provider)
    {command, args, env} = adapter.command([])
    prompt = Template.render(node.prompt || "", context)
    timeout = node.timeout || default_timeout_ms()

    node_dir = Path.join(run_dir, node.id)
    File.mkdir_p!(node_dir)
    Tractor.Paths.atomic_write!(Path.join(node_dir, "prompt.md"), prompt)
    stderr_log = Path.join(node_dir, "stderr.log")

    event_sink = fn %{kind: kind, data: data} ->
      event_kind = if kind == :usage, do: :token_usage, else: kind
      payload = maybe_put_iteration(data, context)

      Tractor.RunEvents.emit(
        Path.basename(run_dir),
        node.id,
        event_kind,
        payload
      )

      maybe_send_runtime_usage(context, node, payload, event_kind)
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
          maybe_send_turn_usage(context, node, turn)

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

  defp response_text(%Tractor.ACP.Turn{response_text: response}), do: response
  defp response_text(response) when is_binary(response), do: response

  defp maybe_put_iteration(data, %{"__iteration__" => iteration}) do
    Map.put(data || %{}, "iteration", iteration)
  end

  defp maybe_put_iteration(data, _context), do: data

  defp status(node, %Tractor.ACP.Turn{token_usage: nil}) do
    %{"status" => "ok", "provider" => node.llm_provider, "model" => node.llm_model}
  end

  defp status(node, %Tractor.ACP.Turn{token_usage: token_usage}) do
    %{
      "status" => "ok",
      "provider" => node.llm_provider,
      "model" => node.llm_model,
      "token_usage" => token_usage
    }
  end

  defp status(node, _response) do
    %{"status" => "ok", "provider" => node.llm_provider, "model" => node.llm_model}
  end

  defp maybe_send_turn_usage(context, node, %Tractor.ACP.Turn{token_usage: token_usage})
       when is_map(token_usage) do
    maybe_send_runtime_usage(context, node, token_usage, :token_usage)
  end

  defp maybe_send_turn_usage(_context, _node, _turn), do: :ok

  defp maybe_send_runtime_usage(context, node, usage, :token_usage) when is_map(usage) do
    case context["__runner_pid__"] do
      runner_pid when is_pid(runner_pid) ->
        send(runner_pid, {
          :token_usage_snapshot,
          %{
            node_id: node.id,
            iteration: context["__iteration__"],
            attempt: context["__attempt__"],
            provider: node.llm_provider,
            model: node.llm_model,
            usage: usage
          }
        })

      _other ->
        :ok
    end
  end

  defp maybe_send_runtime_usage(_context, _node, _usage, _kind), do: :ok
end
