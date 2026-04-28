defmodule Tractor.ValidatorTest do
  use ExUnit.Case, async: true

  alias Tractor.{DotParser, Edge, Node, Pipeline, Validator}
  alias Tractor.Pipeline.ParallelBlock

  test "accepts a linear start to codergen to exit pipeline" do
    assert :ok =
             Validator.validate(
               pipeline(
                 nodes: [
                   node("start", "start"),
                   node("ask", "codergen", llm_provider: "claude"),
                   node("exit", "exit")
                 ],
                 edges: [edge("start", "ask"), edge("ask", "exit")]
               )
             )
  end

  test "rejects start and exit cardinality violations" do
    assert_codes(
      pipeline(nodes: [node("a", "codergen", llm_provider: "codex"), node("exit", "exit")]),
      [:start_cardinality]
    )

    assert_codes(
      pipeline(nodes: [node("start", "start"), node("a", "exit"), node("b", "exit")]),
      [:exit_cardinality]
    )
  end

  test "rejects cycles and missing edge endpoints" do
    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen", llm_provider: "gemini"),
          node("exit", "exit")
        ],
        edges: [edge("start", "ask"), edge("ask", "start")]
      ),
      [:unconditional_cycle, :unreachable_exit]
    )

    assert_codes(
      pipeline(
        nodes: [node("start", "start"), node("exit", "exit")],
        edges: [edge("start", "missing")]
      ),
      [:unknown_edge_endpoint]
    )
  end

  test "allows conditional retry cycles but rejects unconditional subcycles" do
    assert :ok =
             Validator.validate(
               pipeline(
                 nodes: [
                   node("start", "start"),
                   node("ask", "codergen",
                     llm_provider: "gemini",
                     attrs: %{"max_iterations" => "3"}
                   ),
                   node("judge", "judge", attrs: %{"judge_mode" => "stub"}),
                   node("exit", "exit")
                 ],
                 edges: [
                   edge("start", "ask"),
                   edge("ask", "judge"),
                   edge("judge", "ask", condition: "reject"),
                   edge("judge", "exit", condition: "accept")
                 ]
               )
             )

    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("a", "codergen", llm_provider: "gemini"),
          node("b", "codergen", llm_provider: "gemini"),
          node("c", "codergen", llm_provider: "gemini"),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "a"),
          edge("a", "b"),
          edge("b", "a"),
          edge("b", "c", condition: "accept"),
          edge("c", "a", condition: "reject"),
          edge("c", "exit")
        ]
      ),
      [:unconditional_cycle]
    )
  end

  test "rejects disconnected nodes" do
    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen", llm_provider: "codex"),
          node("exit", "exit")
        ],
        edges: [edge("start", "ask")]
      ),
      [:missing_outgoing, :missing_incoming]
    )
  end

  test "rejects codergen nodes without a supported provider" do
    assert_codes(
      pipeline(nodes: [node("start", "start"), node("ask", "codergen"), node("exit", "exit")]),
      [:missing_provider]
    )

    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen", llm_provider: "llama"),
          node("exit", "exit")
        ]
      ),
      [:unknown_provider]
    )
  end

  test "rejects unsupported handlers and attrs" do
    assert_codes(
      pipeline(
        nodes: [node("start", "start"), node("loop", "stack.manager_loop"), node("exit", "exit")]
      ),
      [:unsupported_handler]
    )

    assert_codes(
      pipeline(
        graph_attrs: %{"model_stylesheet" => "x"},
        nodes: [
          node("start", "start"),
          node("ask", "codergen", llm_provider: "codex"),
          node("exit", "exit")
        ],
        edges: [edge("start", "ask", attrs: %{"fidelity" => "high"}), edge("ask", "exit")]
      ),
      [:unsupported_graph_attr, :unsupported_edge_attr]
    )
  end

  test "accepts conditional, tool, and wait.human handlers with valid attrs" do
    assert :ok =
             Validator.validate(
               pipeline(
                 nodes: [
                   node("start", "start"),
                   node("route", "conditional"),
                   node("tool", "tool", attrs: %{"command" => ["echo", "ok"]}),
                   node("wait", "wait.human",
                     attrs: %{"wait_timeout" => "30s", "default_edge" => "skip"}
                   ),
                   node("skip", "codergen", llm_provider: "codex"),
                   node("exit", "exit")
                 ],
                 edges: [
                   edge("start", "route"),
                   edge("route", "tool", attrs: %{"label" => "run"}),
                   edge("route", "wait", attrs: %{"label" => "hold"}),
                   edge("tool", "exit"),
                   edge("wait", "skip", attrs: %{"label" => "skip"}),
                   edge("skip", "exit")
                 ]
               )
             )
  end

  test "validates tool handler attrs" do
    base_nodes = [node("start", "start"), node("tool", "tool"), node("exit", "exit")]
    base_edges = [edge("start", "tool"), edge("tool", "exit")]

    for attrs <- [
          %{},
          %{"command" => "grep -r foo ."},
          %{"command" => []},
          %{"command" => [1, 2, 3]}
        ] do
      assert_codes(pipeline(nodes: put_attrs(base_nodes, "tool", attrs), edges: base_edges), [
        :invalid_tool_command
      ])
    end

    assert_codes(
      pipeline(
        nodes: put_attrs(base_nodes, "tool", %{"command" => ["echo"], "env" => %{"K" => 1}}),
        edges: base_edges
      ),
      [:invalid_tool_env]
    )

    for invalid <- ["0", "100000001", "abc"] do
      assert_codes(
        pipeline(
          nodes:
            put_attrs(base_nodes, "tool", %{
              "command" => ["echo"],
              "max_output_bytes" => invalid
            }),
          edges: base_edges
        ),
        [:invalid_max_output_bytes]
      )
    end
  end

  test "validates wait.human attrs and warnings" do
    assert_codes(
      pipeline(nodes: [node("start", "start"), node("wait", "wait.human"), node("exit", "exit")]),
      [:wait_human_without_outgoing]
    )

    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("wait", "wait.human", attrs: %{"wait_timeout" => "30s"}),
          node("skip", "codergen", llm_provider: "codex"),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "wait"),
          edge("wait", "skip", attrs: %{"label" => "skip"}),
          edge("skip", "exit")
        ]
      ),
      [:wait_without_default]
    )

    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("wait", "wait.human",
            attrs: %{"wait_timeout" => "30s", "default_edge" => "missing"}
          ),
          node("skip", "codergen", llm_provider: "codex"),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "wait"),
          edge("wait", "skip", attrs: %{"label" => "skip"}),
          edge("skip", "exit")
        ]
      ),
      [:invalid_default_edge]
    )

    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("wait", "wait.human",
            attrs: %{"wait_timeout" => "later", "default_edge" => "skip"}
          ),
          node("skip", "codergen", llm_provider: "codex"),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "wait"),
          edge("wait", "skip", attrs: %{"label" => "skip"}),
          edge("skip", "exit")
        ]
      ),
      [:invalid_wait_timeout]
    )

    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("wait", "wait.human"),
          node("skip", "codergen", llm_provider: "codex"),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "wait"),
          edge("wait", "skip", attrs: %{"label" => "skip"}),
          edge("skip", "exit")
        ]
      )

    assert_warning_codes(pipeline, [:wait_human_no_timeout])
  end

  test "validates judge outgoing edge conditions" do
    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("judge", "judge", attrs: %{"judge_mode" => "stub"}),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "judge"),
          edge("judge", "exit", condition: "accept")
        ]
      ),
      [:judge_edge_cardinality]
    )

    assert :ok =
             Validator.validate(
               pipeline(
                 nodes: [
                   node("start", "start"),
                   node("judge", "judge",
                     attrs: %{"judge_mode" => "stub", "allow_partial" => "true"}
                   ),
                   node("partial", "codergen", llm_provider: "codex"),
                   node("exit", "exit"),
                   node("retry", "codergen", llm_provider: "codex")
                 ],
                 edges: [
                   edge("start", "judge"),
                   edge("judge", "exit", condition: "accept"),
                   edge("judge", "retry", condition: "reject"),
                   edge("judge", "partial", condition: "partial_success"),
                   edge("partial", "exit"),
                   edge("retry", "exit")
                 ]
               )
             )
  end

  test "validates non-judge conditional coverage" do
    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("route", "codergen", llm_provider: "codex"),
          node("exit", "exit"),
          node("retry", "codergen", llm_provider: "codex")
        ],
        edges: [
          edge("start", "route"),
          edge("route", "exit", condition: "accept"),
          edge("route", "retry", condition: "maybe")
        ]
      ),
      [:incomplete_condition_coverage]
    )
  end

  test "validates max_iterations bounds" do
    assert_codes(
      pipeline(
        nodes: [node("start", "start", attrs: %{"max_iterations" => "0"}), node("exit", "exit")]
      ),
      [:invalid_max_iterations]
    )
  end

  test "validates retry, timeout, budget, and status-agent attrs" do
    base_nodes = [
      node("start", "start"),
      node("ask", "codergen", llm_provider: "codex"),
      node("exit", "exit")
    ]

    base_edges = [edge("start", "ask"), edge("ask", "exit")]

    for {attrs, code} <- [
          {%{"retries" => "-1"}, :invalid_retry_config},
          {%{"retries" => "11"}, :invalid_retry_config},
          {%{"retry_backoff" => "wobble"}, :invalid_retry_config},
          {%{"retry_base_ms" => "0"}, :invalid_retry_config},
          {%{"max_total_iterations" => "0"}, :invalid_budget},
          {%{"max_wall_clock" => "foo"}, :invalid_budget},
          {%{"max_wall_clock" => "48h"}, :invalid_budget},
          {%{"status_agent" => "gpt4"}, :invalid_status_agent},
          {%{"status_agent_prompt" => "custom"}, :unsupported_attr}
        ] do
      assert_codes(
        pipeline(graph_attrs: attrs, nodes: base_nodes, edges: base_edges),
        [code]
      )
    end

    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen",
            llm_provider: "codex",
            attrs: %{"timeout" => "500ms"},
            timeout: 500
          ),
          node("exit", "exit")
        ],
        edges: base_edges
      ),
      [:invalid_timeout]
    )

    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen",
            llm_provider: "codex",
            attrs: %{"timeout" => "5x"}
          ),
          node("exit", "exit")
        ],
        edges: base_edges
      ),
      [:invalid_timeout]
    )

    for invalid_budget <- ["0", "1001", "abc"] do
      assert_codes(
        pipeline(
          graph_attrs: %{"max_total_cost_usd" => invalid_budget},
          nodes: base_nodes,
          edges: base_edges
        ),
        [:invalid_budget]
      )
    end

    assert :ok =
             Validator.validate(
               pipeline(
                 graph_attrs: %{"max_total_cost_usd" => "0.5"},
                 nodes: base_nodes,
                 edges: base_edges
               )
             )

    assert_warning_diagnostic(
      pipeline(graph_attrs: %{"max_retries" => "3"}, nodes: base_nodes, edges: base_edges),
      :deprecated_attr,
      "max_retries is deprecated"
    )

    assert_warning_diagnostic(
      pipeline(
        graph_attrs: %{"default_max_retries" => "3"},
        nodes: base_nodes,
        edges: base_edges
      ),
      :deprecated_attr,
      "default_max_retries is deprecated"
    )
  end

  test "rejects undirected and strict graphs" do
    assert_codes(
      pipeline(graph_type: :graph, nodes: [node("start", "start"), node("exit", "exit")]),
      [:undirected_graph]
    )

    assert_codes(
      pipeline(strict?: true, nodes: [node("start", "start"), node("exit", "exit")]),
      [:strict_graph]
    )
  end

  test "validates retry target references" do
    base_nodes = [
      node("start", "start"),
      node("ask", "codergen", llm_provider: "codex"),
      node("recover", "codergen", llm_provider: "codex"),
      node("exit", "exit")
    ]

    base_edges = [edge("start", "ask"), edge("ask", "exit"), edge("recover", "exit")]

    for attrs <- [
          %{"retry_target" => "ask"},
          %{"retry_target" => "start"},
          %{"retry_target" => "exit"},
          %{"retry_target" => "recover", "fallback_retry_target" => "recover"}
        ] do
      assert_codes(
        pipeline(
          nodes: put_attrs(base_nodes, "ask", attrs),
          edges: base_edges
        ),
        [:invalid_retry_target]
      )
    end
  end

  test "warns for unreachable retry targets and goal/partial soft validations" do
    retry_warning_pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen", llm_provider: "codex", attrs: %{"retry_target" => "recover"}),
          node("recover", "codergen", llm_provider: "codex"),
          node("exit", "exit")
        ],
        edges: [edge("start", "ask"), edge("ask", "exit"), edge("recover", "exit")]
      )

    assert_warning_codes(retry_warning_pipeline, [:unreachable_retry_target])

    goal_gate_pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("gate", "codergen", llm_provider: "codex", attrs: %{"goal_gate" => "true"}),
          node("skip", "codergen", llm_provider: "codex"),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "gate"),
          edge("start", "skip"),
          edge("gate", "exit"),
          edge("skip", "exit")
        ]
      )

    assert_warning_codes(goal_gate_pipeline, [:goal_gate_bypass])

    allow_partial_pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("judgeable", "codergen",
            llm_provider: "codex",
            attrs: %{"allow_partial" => "true"}
          ),
          node("exit", "exit")
        ],
        edges: [edge("start", "judgeable"), edge("judgeable", "exit")]
      )

    assert_warning_codes(allow_partial_pipeline, [:allow_partial_without_judge])
  end

  test "rejects invalid goal gate, allow_partial, and numeric non-context conditions" do
    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen",
            llm_provider: "codex",
            attrs: %{"goal_gate" => "maybe", "allow_partial" => "sometimes"}
          ),
          node("exit", "exit")
        ],
        edges: [edge("start", "ask"), edge("ask", "exit")]
      ),
      [:invalid_goal_gate, :invalid_allow_partial]
    )

    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen", llm_provider: "codex"),
          node("exit", "exit")
        ],
        edges: [edge("start", "ask", condition: "outcome >= 3"), edge("ask", "exit")]
      ),
      [:invalid_condition]
    )
  end

  test "rejects retry targets inside parallel brackets" do
    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen", llm_provider: "codex", attrs: %{"retry_target" => "branch"}),
          node("branch", "codergen", llm_provider: "codex"),
          node("join", "parallel.fan_in"),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "ask"),
          edge("ask", "exit"),
          edge("branch", "join"),
          edge("join", "exit")
        ],
        parallel_blocks: %{
          "parallel" => %ParallelBlock{
            parallel_node_id: "parallel",
            branches: ["branch"],
            fan_in_id: "join"
          }
        }
      ),
      [:invalid_retry_target]
    )
  end

  test "warns for type and shape mismatch when shape survives lowering attrs" do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "tool",
            llm_provider: nil,
            attrs: %{"type" => "tool", "shape" => "box", "command" => ["echo"]}
          ),
          node("exit", "exit")
        ],
        edges: [edge("start", "ask"), edge("ask", "exit")]
      )

    assert pipeline.nodes["ask"].attrs["shape"] == "box"

    assert_warning_diagnostic(
      pipeline,
      :type_shape_mismatch,
      "shape 'box' implies type 'codergen'"
    )
  end

  test "warns for command on non-tool nodes and prompt on tool nodes" do
    assert_warning_diagnostic(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen",
            llm_provider: "codex",
            attrs: %{"command" => ["echo", "hi"]}
          ),
          node("exit", "exit")
        ],
        edges: [edge("start", "ask"), edge("ask", "exit")]
      ),
      :tool_command_on_non_tool,
      "has command but resolved type is 'codergen'"
    )

    assert_warning_diagnostic(
      pipeline(
        nodes: [
          node("start", "start"),
          node("tool", "tool", attrs: %{"command" => ["echo"], "prompt" => "hi"}),
          node("exit", "exit")
        ],
        edges: [edge("start", "tool"), edge("tool", "exit")]
      ),
      :prompt_on_tool_node,
      "tool node but has a prompt"
    )
  end

  test "warns for goal_gate and llm attrs on non-agent nodes" do
    assert_warning_diagnostic(
      pipeline(
        nodes: [
          node("start", "start"),
          node("tool", "tool", attrs: %{"command" => ["echo"], "goal_gate" => "true"}),
          node("exit", "exit")
        ],
        edges: [edge("start", "tool"), edge("tool", "exit")]
      ),
      :goal_gate_on_non_agent,
      "not an agent-capable node"
    )

    assert_warning_diagnostic(
      pipeline(
        nodes: [
          node("start", "start"),
          node("wait", "wait.human", llm_provider: "codex"),
          node("exit", "exit")
        ],
        edges: [edge("start", "wait"), edge("wait", "exit")]
      ),
      :agent_on_non_agent,
      "LLM attrs are ignored"
    )
  end

  test "warns for timeout on instant nodes and allow_partial without retries" do
    assert_warning_diagnostic(
      pipeline(
        nodes: [
          node("start", "start"),
          node("route", "parallel", attrs: %{"timeout" => "5s"}),
          node("exit", "exit")
        ],
        edges: [edge("start", "route"), edge("route", "exit")]
      ),
      :timeout_on_instant_node,
      "parallel nodes execute instantly"
    )

    assert_warning_diagnostic(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen",
            llm_provider: "codex",
            attrs: %{"allow_partial" => "true"}
          ),
          node("exit", "exit")
        ],
        edges: [edge("start", "ask"), edge("ask", "exit")]
      ),
      :allow_partial_without_retries,
      "effective retries is 0"
    )
  end

  test "warns for two-way edges and principle warnings on wait/tool nodes" do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("gate", "wait.human"),
          node("tool", "tool", attrs: %{"command" => ["echo"]}),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "gate"),
          edge("gate", "tool"),
          edge("tool", "gate"),
          edge("tool", "exit")
        ]
      )

    assert_warning_diagnostic(pipeline, :two_way_edge, "have edges in both directions")
    assert_warning_diagnostic(pipeline, :human_gate_warning, "pipelines should run autonomously")
    assert_warning_diagnostic(pipeline, :tool_node_warning, "tool node running a shell command directly")
  end

  test "splits retry target existence warnings from illegal retry target errors" do
    diagnostics =
      diagnostics(
        pipeline(
          nodes: [
            node("start", "start"),
            node("ask", "codergen", llm_provider: "codex", attrs: %{"retry_target" => "missing"}),
            node("self", "codergen", llm_provider: "codex", attrs: %{"retry_target" => "self"}),
            node("terminal", "codergen",
              llm_provider: "codex",
              attrs: %{"retry_target" => "exit"}
            ),
            node("parallel_node", "codergen",
              llm_provider: "codex",
              attrs: %{"retry_target" => "branch"}
            ),
            node("branch", "codergen", llm_provider: "codex"),
            node("join", "parallel.fan_in"),
            node("exit", "exit")
          ],
          edges: [
            edge("start", "ask"),
            edge("ask", "exit"),
            edge("self", "exit"),
            edge("terminal", "exit"),
            edge("parallel_node", "exit"),
            edge("branch", "join"),
            edge("join", "exit")
          ],
          parallel_blocks: %{
            "parallel" => %ParallelBlock{
              parallel_node_id: "parallel",
              branches: ["branch"],
              fan_in_id: "join"
            }
          }
        )
      )

    assert Enum.count(diagnostics, &(&1.code == :retry_target_exists and &1.severity == :warning)) == 1
    assert Enum.count(diagnostics, &(&1.code == :invalid_retry_target and &1.severity == :error)) == 3
  end

  test "validate and warnings wrappers match diagnostics on example graphs" do
    for path <- Path.wildcard(Path.expand("../../examples/*.dot", __DIR__)) do
      assert {:ok, pipeline} = DotParser.parse_file(path)

      diagnostics = Validator.diagnostics(pipeline)
      warning_diagnostics = Enum.filter(diagnostics, &(&1.severity == :warning))
      error_diagnostics = Enum.filter(diagnostics, &(&1.severity == :error))

      assert Validator.warnings(pipeline) == warning_diagnostics

      expected_validate =
        case error_diagnostics do
          [] -> :ok
          errors -> {:error, errors}
        end

      assert Validator.validate(pipeline) == expected_validate
    end
  end

  defp diagnostics(pipeline), do: Validator.diagnostics(pipeline)

  defp assert_codes(pipeline, expected_codes) do
    assert {:error, diagnostics} = Validator.validate(pipeline)
    assert expected_codes -- Enum.map(diagnostics, & &1.code) == []
  end

  defp assert_warning_codes(pipeline, expected_codes) do
    warnings = Validator.warnings(pipeline)
    assert expected_codes -- Enum.map(warnings, & &1.code) == []
  end

  defp assert_warning_diagnostic(pipeline, code, message_fragment) do
    assert %{
             code: ^code,
             severity: :warning,
             message: message
           } =
             Enum.find(Validator.warnings(pipeline), &(&1.code == code))

    assert String.contains?(message, message_fragment)
  end

  defp pipeline(opts) do
    nodes =
      opts
      |> Keyword.get(:nodes, [])
      |> Map.new(&{&1.id, &1})

    %Pipeline{
      graph_type: Keyword.get(opts, :graph_type, :digraph),
      strict?: Keyword.get(opts, :strict?, false),
      graph_attrs: Keyword.get(opts, :graph_attrs, %{}),
      nodes: nodes,
      edges: Keyword.get(opts, :edges, []),
      parallel_blocks: Keyword.get(opts, :parallel_blocks, %{})
    }
  end

  defp node(id, type, opts \\ []) do
    attrs = Keyword.get(opts, :attrs, %{})

    %Node{
      id: id,
      type: type,
      llm_provider: Keyword.get(opts, :llm_provider),
      timeout: Keyword.get(opts, :timeout),
      attrs: attrs
    }
  end

  defp edge(from, to, opts \\ []) do
    attrs = Keyword.get(opts, :attrs, %{})
    condition = Keyword.get(opts, :condition)
    attrs = if condition, do: Map.put(attrs, "condition", condition), else: attrs
    %Edge{from: from, to: to, condition: condition, attrs: attrs}
  end

  defp put_attrs(nodes, node_id, attrs) do
    Enum.map(nodes, fn
      %Node{id: ^node_id} = node -> %{node | attrs: attrs}
      node -> node
    end)
  end
end
