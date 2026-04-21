defmodule Tractor.Runner.Failure do
  @moduledoc """
  Classifies runtime failure reasons for retry decisions.
  """

  @spec classify(term()) :: :transient | :permanent
  def classify({:handler_crash, _reason}), do: :transient
  def classify(:acp_disconnect), do: :transient
  def classify({:provider_timeout, _reason}), do: :transient
  def classify(:node_timeout), do: :transient
  def classify({:error, :overloaded}), do: :transient
  def classify({:port_exit, _status}), do: :transient
  def classify({:partial_success_not_allowed, _node_id}), do: :transient
  def classify({:tool_failed, _reason}), do: :transient

  def classify({:jsonrpc_error, %{"code" => code}}) when code in [-32_000, -32_001],
    do: :transient

  def classify({:jsonrpc_error, %{code: code}}) when code in [-32_000, -32_001], do: :transient
  def classify(:timeout), do: :transient

  def classify(:judge_parse_error), do: :permanent
  def classify({:invalid_attr, _reason}), do: :permanent
  def classify({:tool_not_found, _binary}), do: :permanent

  def classify(reason) when is_tuple(reason) do
    reason
    |> elem(0)
    |> to_string()
    |> String.starts_with?("invalid_")
    |> if(do: :permanent, else: :permanent)
  end

  def classify(_reason), do: :permanent
end
