defmodule Tractor.Handler.Judge do
  @moduledoc """
  Judge handler for accept/reject routing.
  """

  @behaviour Tractor.Handler

  alias Tractor.Context.Template
  alias Tractor.Node

  @default_timeout 300_000
  @provider_modules %{
    "claude" => Tractor.Agent.Claude,
    "codex" => Tractor.Agent.Codex,
    "gemini" => Tractor.Agent.Gemini
  }

  @impl Tractor.Handler
  def default_timeout_ms, do: @default_timeout

  @impl Tractor.Handler
  def run(%Node{attrs: attrs} = node, context, run_dir) do
    case Map.get(attrs, "judge_mode", "llm") do
      "stub" -> run_stub(node, context)
      "llm" -> run_llm(node, context, run_dir)
      other -> {:error, {:unsupported_judge_mode, other}}
    end
  end

  defp run_stub(%Node{} = node, context) do
    probability = parse_probability(node.attrs["reject_probability"] || "0.5")
    iteration = context["__iteration__"] || 1
    run_id = context["__run_id__"] || "run"

    verdict =
      if deterministic_random(run_id, node.id, iteration) < probability do
        "reject"
      else
        "accept"
      end

    critique =
      case verdict do
        "accept" -> node.attrs["accept_critique"] || "accepted"
        "reject" -> node.attrs["reject_critique"] || "rejected; revise and try again"
      end

    response = Jason.encode!(%{"verdict" => verdict, "critique" => critique}, pretty: true)
    emit_verdict(context, node.id, iteration, verdict, critique)

    {:ok, response, judge_updates(node, response, verdict, critique, :stub)}
  end

  defp run_llm(%Node{} = node, context, run_dir) do
    with provider when is_binary(provider) <- node.llm_provider || node.attrs["llm_provider"],
         {:ok, adapter} <- fetch_provider(provider),
         {:ok, response, rendered_prompt, provider_command, turn} <-
           prompt_llm(node, context, run_dir, adapter, provider),
         {:ok, verdict, critique} <- parse_verdict(response) do
      iteration = context["__iteration__"] || 1
      emit_verdict(context, node.id, iteration, verdict, critique)
      maybe_send_turn_usage(context, node, turn)

      updates =
        node
        |> judge_updates(response, verdict, critique, :llm)
        |> Map.put(:prompt, rendered_prompt)
        |> Map.put(:provider_command, provider_command)

      {:ok, response, updates}
    else
      nil -> {:error, :missing_provider}
      {:error, :judge_parse_error} -> {:error, :judge_parse_error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_provider(provider) do
    case Map.fetch(@provider_modules, provider) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unknown_provider, provider}}
    end
  end

  defp prompt_llm(node, context, run_dir, adapter, provider) do
    agent_client = Application.get_env(:tractor, :agent_client, Tractor.ACP.Session)
    prompt = Template.render(node.prompt || default_prompt(), context)
    timeout = node.timeout || default_timeout_ms()
    node_dir = Path.join(run_dir, node.id)
    File.mkdir_p!(node_dir)
    Tractor.Paths.atomic_write!(Path.join(node_dir, "prompt.md"), prompt)
    stderr_log = Path.join(node_dir, "stderr.log")
    {command, args, env} = adapter.command([])

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
          provider_command = %{provider: provider, command: command, args: args, env: env}
          {:ok, response_text(turn), prompt, provider_command, turn}

        {:error, reason} ->
          :ok = agent_client.stop(session)
          {:error, reason}
      end
    end
  end

  defp default_prompt do
    """
    Return JSON with exactly these keys:
    {"verdict":"accept|reject","critique":"short critique"}
    """
    |> String.trim()
  end

  defp parse_verdict(response) do
    with {:ok, json} <- first_json_object(response),
         {:ok, data} <- Jason.decode(json),
         verdict when verdict in ["accept", "reject", "partial_success"] <-
           normalize_verdict(data["verdict"]),
         critique when is_binary(critique) <- data["critique"] || "" do
      {:ok, verdict, critique}
    else
      _other -> {:error, :judge_parse_error}
    end
  end

  defp first_json_object(response) when is_binary(response) do
    case Regex.run(~r/\{.*\}/sU, response) do
      [json] -> {:ok, json}
      _other -> {:error, :judge_parse_error}
    end
  end

  defp normalize_verdict(verdict) when is_binary(verdict) do
    verdict |> String.trim() |> String.downcase()
  end

  defp normalize_verdict(_verdict), do: nil

  defp judge_updates(node, response, verdict, critique, mode) do
    %{
      prompt: node.prompt,
      response: response,
      status: %{
        "status" => verdict_status(verdict),
        "judge_mode" => to_string(mode),
        "verdict" => verdict,
        "critique" => critique,
        "provider" => node.llm_provider,
        "model" => node.llm_model
      },
      preferred_label: verdict,
      verdict: String.to_atom(verdict),
      critique: critique,
      context: context_updates(node, verdict, critique)
    }
  end

  defp context_updates(node, verdict, critique) do
    critique_key = node.attrs["critique_key"] || "last_critique"

    %{
      critique_key => critique,
      "last_verdict" => verdict,
      "#{node.id}.last_verdict" => verdict,
      "#{node.id}.last_critique" => critique
    }
  end

  defp emit_verdict(context, node_id, iteration, verdict, critique) do
    case {Process.whereis(Tractor.RunEvents), context["__run_id__"]} do
      {nil, _run_id} ->
        :ok

      {_pid, run_id} when is_binary(run_id) ->
        Tractor.RunEvents.emit(run_id, node_id, :judge_verdict, %{
          "node_id" => node_id,
          "iteration" => iteration,
          "verdict" => verdict,
          "critique" => critique
        })

      _other ->
        :ok
    end
  end

  defp parse_probability(value) do
    case Float.parse(to_string(value)) do
      {number, ""} -> min(max(number, 0.0), 1.0)
      _other -> 0.5
    end
  end

  defp deterministic_random(run_id, node_id, iteration) do
    <<a::32, b::32, c::32>> =
      :crypto.hash(:sha256, "#{run_id}:#{node_id}:#{iteration}") |> binary_part(0, 12)

    :rand.seed(:exsplus, {a, b, c})
    :rand.uniform()
  end

  defp response_text(%Tractor.ACP.Turn{response_text: response}), do: response
  defp response_text(response) when is_binary(response), do: response

  defp maybe_put_iteration(data, %{"__iteration__" => iteration}) do
    Map.put(data || %{}, "iteration", iteration)
  end

  defp maybe_put_iteration(data, _context), do: data

  defp verdict_status("partial_success"), do: "partial_success"
  defp verdict_status(_verdict), do: "success"

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
