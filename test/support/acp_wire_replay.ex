defmodule ACPWireReplay do
  @moduledoc """
  Drives `Tractor.ACP.Session` from a captured wire-log fixture.

  Used by `test/tractor/acp/wire_replay_test.exs` to assert the session's
  parser survives every line in a redacted production wire log without
  crashing, and that the event sink sees the expected sequence of events.

  Fixtures live at `test/fixtures/acp/wire_logs/*.jsonl`. They follow the
  same `direction|payload` schema that `Tractor.ACP.Session.write_wire/3`
  produces. Only `direction: "in"` rows are injected — outbound frames go
  to a silent fake agent and are discarded. Redaction policy: see
  `docs/notes/acp-wire-replay.md`.

  The 1MiB line-buffer in the session is exercised by splitting frames
  longer than `:split_at` bytes into a sequence of `:noeol` chunks
  terminated by `:eol`, mirroring the `+exit_status` / line-mode behaviour
  of `Port.open/2` against a large stdout write.
  """

  alias Tractor.ACP.Session

  @line_split_default 1024 * 1024

  @doc """
  Replays the fixture at `path` into a fresh `Session`. Returns
  `{:ok, %{events: [...], session_pid: pid, telemetry: [...]}}` on success.

  Options:

    * `:agent_module` — defaults to a built-in silent-loop agent.
    * `:split_at` — split frames longer than this byte size into `:noeol`
      chunks. Defaults to `#{@line_split_default}` (the session's line
      buffer limit).
    * `:timeout` — per-frame wait between injection and the next read.
      Defaults to 25ms.
  """
  @spec run_fixture(Path.t(), keyword()) :: {:ok, map()}
  def run_fixture(path, opts \\ []) do
    parent = self()
    sink = fn event -> send(parent, {:replay_sink, event.kind, event.data}) end

    telemetry_ref = make_ref()

    :telemetry.attach(
      {:acp_wire_replay, telemetry_ref},
      [:tractor, :acp, :unhandled],
      fn _name, measurements, metadata, _config ->
        send(parent, {:replay_telemetry, measurements, metadata})
      end,
      nil
    )

    agent_module = Keyword.get(opts, :agent_module, __MODULE__.SilentFakeAgent)
    split_at = Keyword.get(opts, :split_at, @line_split_default)
    timeout = Keyword.get(opts, :timeout, 25)

    {:ok, pid} =
      Session.start_link(agent_module,
        cwd: File.cwd!(),
        event_sink: sink
      )

    inbound_frames =
      path
      |> File.stream!()
      |> Stream.map(&Jason.decode!/1)
      |> Stream.filter(&(&1["direction"] == "in"))
      |> Stream.map(& &1["payload"])
      |> Enum.to_list()

    %{port: port} = :sys.get_state(pid)

    # Drive a real prompt() in a background task. The fixture's first two
    # frames complete the init handshake; once the session is :idle the queued
    # prompt advances to :prompting, which is the state in which
    # session/update notifications are actually captured. The final frame
    # carries the prompt result and unblocks the task.
    prompt_caller =
      Task.async(fn ->
        Session.prompt(pid, "fixture-driven prompt", :infinity)
      end)

    Enum.each(inbound_frames, fn payload ->
      line = Jason.encode!(payload)
      inject_line(pid, port, line, split_at)
      Process.sleep(timeout)
    end)

    prompt_result = Task.await(prompt_caller, 5_000)

    # Drain the mailbox.
    events = drain_sink([])
    telemetry = drain_telemetry([])

    :telemetry.detach({:acp_wire_replay, telemetry_ref})
    :ok = Session.stop(pid)

    {:ok,
     %{
       events: events,
       session_pid: pid,
       telemetry: telemetry,
       prompt_result: prompt_result
     }}
  end

  defp inject_line(pid, port, line, split_at) when byte_size(line) <= split_at do
    send(pid, {port, {:data, {:eol, line}}})
  end

  defp inject_line(pid, port, line, split_at) do
    <<chunk::binary-size(split_at), rest::binary>> = line
    send(pid, {port, {:data, {:noeol, chunk}}})
    inject_line(pid, port, rest, split_at)
  end

  defp drain_sink(acc) do
    receive do
      {:replay_sink, kind, data} -> drain_sink([{kind, data} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp drain_telemetry(acc) do
    receive do
      {:replay_telemetry, measurements, metadata} ->
        drain_telemetry([%{measurements: measurements, metadata: metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defmodule SilentFakeAgent do
    @moduledoc false

    def command(opts) do
      elixir = System.fetch_env!("TRACTOR_TEST_ELIXIR")

      args = [
        "--erl",
        "-kernel logger_level emergency",
        "-pa",
        Path.expand("../../_build/test/lib/jason/ebin", __DIR__),
        Path.expand("../support/fake_acp_agent.exs", __DIR__)
      ]

      env =
        Keyword.get(opts, :env, []) ++
          [{"TRACTOR_FAKE_ACP_MODE", "silent"}]

      {elixir, args, env}
    end
  end
end
