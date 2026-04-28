defmodule Tractor.Node do
  @moduledoc """
  Normalized DOT node owned by Tractor.
  """

  alias Tractor.{Duration, Pipeline}

  @type attr_value :: String.t() | [term()] | %{String.t() => term()}

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t() | nil,
          label: String.t() | nil,
          prompt: String.t() | nil,
          llm_provider: String.t() | nil,
          llm_model: String.t() | nil,
          timeout: timeout_ms(),
          retries: non_neg_integer() | nil,
          retry_backoff: String.t() | nil,
          retry_base_ms: pos_integer() | nil,
          retry_cap_ms: pos_integer() | nil,
          retry_jitter: boolean() | nil,
          retry_target: String.t() | nil,
          fallback_retry_target: String.t() | nil,
          goal_gate: boolean() | nil,
          allow_partial: boolean() | nil,
          attrs: %{String.t() => attr_value()}
        }

  @type timeout_ms :: non_neg_integer() | nil

  defstruct id: nil,
            type: nil,
            label: nil,
            prompt: nil,
            llm_provider: nil,
            llm_model: nil,
            timeout: nil,
            retries: nil,
            retry_backoff: nil,
            retry_base_ms: nil,
            retry_cap_ms: nil,
            retry_jitter: nil,
            retry_target: nil,
            fallback_retry_target: nil,
            goal_gate: nil,
            allow_partial: nil,
            attrs: %{}

  @default_retry_config %{
    retries: 0,
    retry_backoff: "exp",
    retry_base_ms: 1_000,
    retry_cap_ms: 30_000,
    retry_jitter: true
  }

  @shape_types %{
    "Mdiamond" => "start",
    "Msquare" => "exit",
    "box" => "codergen",
    "diamond" => "conditional",
    "hexagon" => "wait.human",
    "parallelogram" => "tool",
    "component" => "parallel",
    "tripleoctagon" => "parallel.fan_in"
  }

  @spec implied_type_from_shape(String.t() | nil) :: String.t() | nil
  def implied_type_from_shape(shape) when is_binary(shape), do: Map.get(@shape_types, shape)
  def implied_type_from_shape(_shape), do: nil

  @spec join_policy(t()) :: String.t()
  def join_policy(%__MODULE__{attrs: attrs}) do
    Map.get(attrs, "join_policy", "wait_all")
  end

  @spec max_parallel(t()) :: pos_integer()
  def max_parallel(%__MODULE__{attrs: attrs}) do
    case Integer.parse(Map.get(attrs, "max_parallel", "4")) do
      {value, ""} -> value
      _other -> 4
    end
  end

  @spec max_iterations(t()) :: pos_integer()
  def max_iterations(%__MODULE__{attrs: attrs}) do
    case Integer.parse(Map.get(attrs, "max_iterations", "3")) do
      {value, ""} -> value
      _other -> 3
    end
  end

  @spec command(t()) :: [String.t()] | nil
  def command(%__MODULE__{attrs: attrs}) do
    case Map.get(attrs, "command") do
      command when is_list(command) ->
        if Enum.all?(command, &is_binary/1), do: command, else: nil

      _other ->
        nil
    end
  end

  @spec cwd(t()) :: String.t() | nil
  def cwd(%__MODULE__{attrs: attrs}), do: blank_to_nil(attrs["cwd"])

  @spec env(t()) :: %{String.t() => String.t()} | nil
  def env(%__MODULE__{attrs: attrs}) do
    case Map.get(attrs, "env") do
      env when is_map(env) -> env |> string_string_map?() |> env_or_nil(env)
      _other -> nil
    end
  end

  defp string_string_map?(env),
    do: Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end)

  defp env_or_nil(true, env), do: Map.new(env)
  defp env_or_nil(false, _env), do: nil

  @spec stdin(t()) :: String.t() | nil
  def stdin(%__MODULE__{attrs: attrs}) do
    case Map.get(attrs, "stdin") do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  @spec max_output_bytes(t()) :: pos_integer()
  def max_output_bytes(%__MODULE__{attrs: attrs}) do
    case parse_integer(attrs["max_output_bytes"]) do
      value when is_integer(value) and value > 0 -> value
      _other -> 1_000_000
    end
  end

  @spec wait_timeout_ms(t()) :: timeout_ms()
  def wait_timeout_ms(%__MODULE__{attrs: attrs}) do
    case blank_to_nil(attrs["wait_timeout"]) do
      nil ->
        nil

      value ->
        case Duration.parse(value) do
          {:ok, timeout_ms} -> timeout_ms
          {:error, :invalid_duration} -> nil
        end
    end
  end

  @spec default_edge(t()) :: String.t() | nil
  def default_edge(%__MODULE__{attrs: attrs}), do: blank_to_nil(attrs["default_edge"])

  @spec wait_prompt(t()) :: String.t() | nil
  def wait_prompt(%__MODULE__{attrs: attrs}), do: blank_to_nil(attrs["wait_prompt"])

  @spec outgoing_labels(t(), Pipeline.t()) :: [String.t()]
  def outgoing_labels(%__MODULE__{id: node_id}, %Pipeline{edges: edges}) do
    edges
    |> Enum.filter(&(&1.from == node_id))
    |> Enum.map(fn edge -> blank_to_nil(edge.label || edge.attrs["label"]) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec retry_config(t(), map()) :: map()
  def retry_config(%__MODULE__{} = node, graph_attrs \\ %{}) do
    @default_retry_config
    |> Map.merge(retry_config_from_attrs(graph_attrs))
    |> Map.merge(retry_config_from_attrs(node.attrs))
    |> maybe_put(:retries, node.retries)
    |> maybe_put(:retry_backoff, node.retry_backoff)
    |> maybe_put(:retry_base_ms, node.retry_base_ms)
    |> maybe_put(:retry_cap_ms, node.retry_cap_ms)
    |> maybe_put(:retry_jitter, node.retry_jitter)
  end

  @spec retry_target(t()) :: String.t() | nil
  def retry_target(%__MODULE__{retry_target: retry_target}) when is_binary(retry_target),
    do: retry_target

  def retry_target(%__MODULE__{attrs: attrs}), do: blank_to_nil(attrs["retry_target"])

  @spec fallback_retry_target(t()) :: String.t() | nil
  def fallback_retry_target(%__MODULE__{fallback_retry_target: retry_target})
      when is_binary(retry_target),
      do: retry_target

  def fallback_retry_target(%__MODULE__{attrs: attrs}),
    do: blank_to_nil(attrs["fallback_retry_target"])

  @spec goal_gate?(t()) :: boolean()
  def goal_gate?(%__MODULE__{goal_gate: goal_gate}) when is_boolean(goal_gate), do: goal_gate
  def goal_gate?(%__MODULE__{attrs: attrs}), do: parse_boolean(attrs["goal_gate"]) || false

  @spec allow_partial?(t()) :: boolean()
  def allow_partial?(%__MODULE__{allow_partial: allow_partial}) when is_boolean(allow_partial),
    do: allow_partial

  def allow_partial?(%__MODULE__{attrs: attrs}),
    do: parse_boolean(attrs["allow_partial"]) || false

  defp retry_config_from_attrs(attrs) do
    %{}
    |> maybe_put(:retries, parse_integer(attrs["retries"]))
    |> maybe_put(:retry_backoff, attrs["retry_backoff"])
    |> maybe_put(:retry_base_ms, parse_integer(attrs["retry_base_ms"]))
    |> maybe_put(:retry_cap_ms, parse_integer(attrs["retry_cap_ms"]))
    |> maybe_put(:retry_jitter, parse_boolean(attrs["retry_jitter"]))
  end

  defp parse_integer(nil), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp parse_boolean(nil), do: nil
  defp parse_boolean(value) when is_boolean(value), do: value
  defp parse_boolean("true"), do: true
  defp parse_boolean("false"), do: false
  defp parse_boolean(_value), do: nil

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
