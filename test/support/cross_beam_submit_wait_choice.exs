Application.put_env(:tractor, :runs_dir, Path.expand(Enum.at(System.argv(), 1)))

case System.argv() do
  [run_id, _runs_dir, node_id, label] ->
    case Tractor.Run.submit_wait_choice(run_id, node_id, label) do
      :ok ->
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, inspect(reason))
        System.halt(1)
    end

  _other ->
    IO.puts(:stderr, "usage: cross_beam_submit_wait_choice.exs RUN_ID RUNS_DIR NODE_ID LABEL")
    System.halt(64)
end
