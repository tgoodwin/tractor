defmodule Tractor.Handler.FanIn do
  @moduledoc """
  Consolidates results from a completed parallel block.
  """

  @behaviour Tractor.Handler

  alias Tractor.ACP.Turn
  alias Tractor.Context.Template
  alias Tractor.Handler.Codergen
  alias Tractor.Node

  @status_rank %{"success" => 3, "partial_success" => 2, "failed" => 1}
  @default_timeout 120_000

  @impl Tractor.Handler
  def default_timeout_ms, do: @default_timeout

  @impl Tractor.Handler
  def run(%Node{} = node, context, run_dir) do
    with {:ok, parallel_id, results} <- fetch_results(context),
         {:ok, best} <- select_best(results) do
      summary = summary(parallel_id, results, best)

      if node.llm_provider do
        run_llm_fan_in(node, context, run_dir, summary, best, results)
      else
        {:ok, summary, fan_in_updates(summary, best)}
      end
    end
  end

  def select_best([]), do: {:error, :all_branches_failed}

  def select_best(results) do
    successful = Enum.filter(results, &(&1["status"] in ["success", "partial_success"]))

    case successful do
      [] ->
        {:error, :all_branches_failed}

      candidates ->
        {:ok,
         Enum.max_by(candidates, fn result ->
           {
             Map.get(@status_rank, result["status"], 0),
             score(result),
             result["branch_id"] || ""
           }
         end)}
    end
  end

  defp fetch_results(context) do
    case Enum.find(context, fn {key, _value} ->
           String.starts_with?(to_string(key), "parallel.results.")
         end) do
      {key, results} when is_list(results) ->
        {:ok, String.replace_prefix(key, "parallel.results.", ""), results}

      _other ->
        {:error, :all_branches_failed}
    end
  end

  defp run_llm_fan_in(node, context, run_dir, summary, best, results) do
    prompt =
      node.prompt
      |> Kernel.||(summary)
      |> render_branch_prompt(results, summary)

    Codergen.run(
      %{node | prompt: prompt, timeout: node.timeout || default_timeout_ms()},
      context,
      run_dir
    )
    |> case do
      {:ok, response, updates} ->
        {:ok, response, merge_fan_in_updates(updates, response, best)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp render_branch_prompt(prompt, results, summary) do
    branch_context =
      Map.new(results, fn result ->
        {"branch:#{result["branch_id"]}", inspect(result["outcome"])}
      end)

    Template.render(prompt, Map.put(branch_context, "branch_responses", summary))
  end

  defp fan_in_updates(summary, best) do
    %{
      response: summary,
      status: %{"status" => "ok"},
      context: %{
        "parallel.fan_in.best_id" => best["branch_id"],
        "parallel.fan_in.best_outcome" => best["outcome"],
        "parallel.fan_in.summary" => summary
      }
    }
  end

  defp merge_fan_in_updates(updates, response, best) do
    updates
    |> Map.put(:response, response_text(response))
    |> Map.update(:context, fan_in_updates(response_text(response), best).context, fn context ->
      Map.merge(context, fan_in_updates(response_text(response), best).context)
    end)
  end

  defp summary(parallel_id, results, best) do
    branches =
      Enum.map_join(results, "\n", fn result ->
        "- #{result["branch_id"]}: #{result["status"]} #{inspect(result["outcome"])}"
      end)

    """
    Parallel block #{parallel_id} results:
    #{branches}

    Best branch: #{best["branch_id"]}
    """
    |> String.trim()
  end

  defp score(%{"score" => score}) when is_number(score), do: score
  defp score(%{"outcome" => %{"score" => score}}) when is_number(score), do: score
  defp score(_result), do: 0

  defp response_text(%Turn{response_text: response}), do: response
  defp response_text(response) when is_binary(response), do: response
end
