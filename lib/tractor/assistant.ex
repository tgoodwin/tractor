defmodule Tractor.Assistant do
  @moduledoc """
  Q&A helper for the run observer. Reads the run's event log, packages it
  with the user's question + chat history, and asks the configured ACP
  provider for a single-turn answer.

  One ACP session per question. Stateless across turns: the chat history is
  re-sent each time. Good enough for an MVP; can be upgraded to a long-lived
  session later if latency becomes a problem.
  """

  alias Tractor.ACP.Turn

  @default_timeout 180_000
  @default_provider Tractor.Agent.Claude
  @max_event_chars 60_000

  @type message :: %{role: :user | :assistant, content: String.t()}

  @spec ask(Path.t(), String.t(), [message()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def ask(run_dir, question, history \\ [], opts \\ []) do
    agent_client = Application.get_env(:tractor, :agent_client, Tractor.ACP.Session)
    provider = Keyword.get(opts, :provider, @default_provider)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    prompt = build_prompt(run_dir, question, history)

    with {:ok, session} <-
           agent_client.start_session(provider,
             cwd: run_dir,
             event_sink: fn _event -> :ok end
           ) do
      try do
        case agent_client.prompt(session, prompt, timeout) do
          {:ok, %Turn{response_text: text}} when is_binary(text) and text != "" ->
            {:ok, text}

          {:ok, %Turn{}} ->
            {:error, :empty_response}

          {:error, reason} ->
            {:error, reason}
        end
      after
        agent_client.stop(session)
      end
    end
  end

  @spec build_prompt(Path.t(), String.t(), [message()]) :: String.t()
  def build_prompt(run_dir, question, history) do
    events = collect_events(run_dir)
    run_id = Path.basename(run_dir)

    [
      preamble(run_id),
      "## Run event log\n\n",
      "```\n",
      events,
      "\n```\n\n",
      render_history(history),
      "## New question\n\n",
      question,
      "\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp preamble(run_id) do
    """
    You are an assistant embedded in the Tractor run observer. The user is
    inspecting a pipeline run and wants to understand what happened.

    Run id: #{run_id}

    The event log below is the concatenation of `events.jsonl` files from
    every node in the run, plus the `_run` stream. Each line is a JSON
    object with `kind`, `seq`, `ts`, and `data`. Use it to ground your
    answers; when you cite something, reference the node and event kind
    (e.g. "node `judge` emitted `judge_verdict` with verdict=reject at
    23:55").

    Keep responses concise and skim-friendly. Markdown is fine. If the log
    doesn't contain enough information to answer, say so plainly.

    """
  end

  defp render_history([]), do: ""

  defp render_history(history) do
    rendered =
      history
      |> Enum.map(fn
        %{role: :user, content: c} -> "User: #{c}"
        %{role: :assistant, content: c} -> "Assistant: #{c}"
      end)
      |> Enum.join("\n\n")

    "## Conversation so far\n\n" <> rendered <> "\n\n"
  end

  defp collect_events(run_dir) do
    case File.ls(run_dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(&node_events(run_dir, &1))
        |> Enum.join("\n")
        |> truncate(@max_event_chars)

      _ ->
        ""
    end
  end

  defp node_events(run_dir, entry) do
    path = Path.join([run_dir, entry, "events.jsonl"])

    cond do
      not File.dir?(Path.join(run_dir, entry)) -> []
      not File.exists?(path) -> []
      true -> ["# node: #{entry}", File.read!(path) |> String.trim_trailing()]
    end
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    head = binary_part(text, 0, div(max, 2))
    tail = binary_part(text, byte_size(text) - div(max, 2), div(max, 2))
    head <> "\n\n[... event log truncated to fit prompt ...]\n\n" <> tail
  end
end
