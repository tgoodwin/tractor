defmodule Tractor.AllowPartialRunTest do
  use ExUnit.Case, async: false

  import Mox

  alias Tractor.{DotParser, Run}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    original = Application.get_env(:tractor, :agent_client)
    Application.put_env(:tractor, :agent_client, Tractor.AgentClientMock)

    on_exit(fn ->
      if original do
        Application.put_env(:tractor, :agent_client, original)
      else
        Application.delete_env(:tractor, :agent_client)
      end
    end)
  end

  @tag :tmp_dir
  test "allow_partial lets judge partial_success route through the partial_success edge", %{
    tmp_dir: tmp_dir
  } do
    pipeline =
      dot_pipeline(
        tmp_dir,
        "allow_partial.dot",
        """
        digraph {
          start [shape=Mdiamond]
          judge [
            shape=ellipse,
            type=judge,
            llm_provider=codex,
            llm_model="gpt-5",
            allow_partial=true,
            prompt="Judge"
          ]
          partial [shape=box, llm_provider=codex, prompt="Partial"]
          exit [shape=Msquare]

          start -> judge
          judge -> partial [condition="partial_success"]
          judge -> exit [condition="accept"]
          judge -> exit [condition="reject", label="reject"]
          partial -> exit
        }
        """
      )

    expect_codex_sequence([
      {"Judge",
       {:ok,
        %Tractor.ACP.Turn{
          response_text: "{\"verdict\":\"partial_success\",\"critique\":\"good enough\"}"
        }}},
      {"Partial", {:ok, "continued"}}
    ])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "allow-partial")
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["partial"] == "continued"
  end

  @tag :tmp_dir
  test "partial_success without allow_partial stays on the failure path", %{tmp_dir: tmp_dir} do
    pipeline =
      dot_pipeline(
        tmp_dir,
        "partial_without_allow.dot",
        """
        digraph {
          start [shape=Mdiamond]
          judge [
            shape=ellipse,
            type=judge,
            llm_provider=codex,
            llm_model="gpt-5",
            prompt="Judge"
          ]
          exit [shape=Msquare]

          start -> judge
          judge -> exit [condition="partial_success"]
          judge -> exit [condition="accept"]
          judge -> exit [condition="reject", label="reject"]
        }
        """
      )

    expect_codex_sequence([
      {"Judge",
       {:ok,
        %Tractor.ACP.Turn{
          response_text: "{\"verdict\":\"partial_success\",\"critique\":\"not enough\"}"
        }}}
    ])

    assert {:ok, run_id} =
             Run.start(pipeline, runs_dir: tmp_dir, run_id: "partial-without-allow")

    assert {:error, {:retries_exhausted, {:partial_success_not_allowed, "judge"}}} =
             Run.await(run_id, 2_000)
  end

  defp dot_pipeline(tmp_dir, filename, dot) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, dot)
    {:ok, pipeline} = DotParser.parse_file(path)
    pipeline
  end

  defp expect_codex_sequence(steps) do
    expect(Tractor.AgentClientMock, :start_session, length(steps), fn Tractor.Agent.Codex,
                                                                      _opts ->
      {:ok, self()}
    end)

    Enum.each(steps, fn
      {prompt, {:ok, %Tractor.ACP.Turn{} = turn}} ->
        expect(Tractor.AgentClientMock, :prompt, fn _pid, ^prompt, timeout
                                                    when timeout in [300_000, 600_000] ->
          {:ok, turn}
        end)

      {prompt, {:ok, response}} ->
        expect(Tractor.AgentClientMock, :prompt, fn _pid, ^prompt, timeout
                                                    when timeout in [300_000, 600_000] ->
          {:ok, response}
        end)
    end)

    Enum.each(steps, fn _step ->
      expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
    end)
  end
end
