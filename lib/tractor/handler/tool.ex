defmodule Tractor.Handler.Tool do
  @moduledoc """
  Executes literal argv tool commands with bounded output capture.
  """

  @behaviour Tractor.Handler

  alias Tractor.Context.Template
  alias Tractor.{Node, Paths, RunEvents}

  defmodule OutputCapture do
    @moduledoc false

    defstruct limit: 0,
              observed_bytes: 0,
              captured_bytes: 0,
              chunks: [],
              truncated?: false

    def new(limit), do: %__MODULE__{limit: limit}

    def push(%__MODULE__{} = capture, chunk) when is_binary(chunk) do
      observed_bytes = min(capture.observed_bytes + byte_size(chunk), capture.limit + 1_024)
      available = max(capture.limit - capture.captured_bytes, 0)

      {captured_bytes, chunks, truncated?} =
        cond do
          available <= 0 ->
            {capture.captured_bytes, capture.chunks, true}

          byte_size(chunk) <= available ->
            {
              capture.captured_bytes + byte_size(chunk),
              [chunk | capture.chunks],
              capture.truncated?
            }

          true ->
            {
              capture.limit,
              [binary_part(chunk, 0, available) | capture.chunks],
              true
            }
        end

      %__MODULE__{
        capture
        | observed_bytes: observed_bytes,
          captured_bytes: captured_bytes,
          chunks: chunks,
          truncated?: truncated?
      }
    end

    def output(%__MODULE__{chunks: chunks}) do
      chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  @impl Tractor.Handler
  def run(%Node{} = node, context, run_dir) do
    command = Node.command(node) || []
    stdin = Template.render(Node.stdin(node) || "", context)
    cwd = resolve_cwd(Node.cwd(node), run_dir)
    env = Node.env(node) || %{}
    max_output_bytes = Node.max_output_bytes(node)
    attempt = context["__attempt__"] || 1

    with [binary | args] <- command,
         {:ok, executable} <- resolve_executable(binary, cwd),
         {:ok, {capture, exit_status}} <-
           invoke_command(executable, args, stdin, cwd, env, max_output_bytes) do
      output = OutputCapture.output(capture)
      run_id = context["__run_id__"] || Path.basename(run_dir)

      if capture.truncated? do
        RunEvents.emit(run_id, node.id, :tool_output_truncated, %{
          "stream" => "stdout",
          "observed_bytes" => capture.observed_bytes,
          "limit" => max_output_bytes
        })
      end

      RunEvents.emit(run_id, node.id, :tool_invoked, %{
        "command" => command,
        "cwd" => cwd,
        "exit_status" => exit_status,
        "attempt" => attempt
      })

      command_artifact = %{
        command: command,
        cwd: cwd,
        env: env,
        stderr_to_stdout: true,
        truncation: %{stdout: capture.truncated?, stderr: false},
        exit_status: exit_status
      }

      write_command_artifact(run_dir, node.id, attempt, command_artifact)

      case exit_status do
        0 ->
          tool_output = %{
            "exit_status" => 0,
            "stdout" => output,
            "stderr" => "",
            "command" => command
          }

          {:ok, tool_output,
           %{
             response: output,
             context: %{
               "#{node.id}.stdout" => output,
               "#{node.id}.stderr" => "",
               "#{node.id}.exit_status" => 0,
               "#{node.id}.command" => command
             },
             status: %{"status" => "ok", "provider" => nil, "model" => nil}
           }}

        status ->
          {:error, {:tool_failed, %{exit_status: status, stderr: output}}}
      end
    else
      [] ->
        {:error, {:tool_not_found, nil}}

      {:error, {:tool_not_found, _binary} = reason} ->
        {:error, reason}
    end
  end

  defp command_options("", cwd, env, max_output_bytes) do
    [
      cd: cwd,
      env: Map.to_list(env),
      stderr_to_stdout: true,
      into: OutputCapture.new(max_output_bytes)
    ]
  end

  defp invoke_command(executable, args, "", cwd, env, max_output_bytes) do
    {:ok, System.cmd(executable, args, command_options("", cwd, env, max_output_bytes))}
  end

  defp invoke_command(executable, args, stdin, cwd, env, max_output_bytes) do
    stdin_file =
      Path.join(
        System.tmp_dir!(),
        "tractor-tool-stdin-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(stdin_file, stdin)

    options =
      command_options("", cwd, env, max_output_bytes)
      |> Keyword.update!(:env, &[{"TRACTOR_TOOL_STDIN_FILE", stdin_file} | &1])

    try do
      {:ok,
       System.cmd(
         System.find_executable("sh"),
         ["-c", "exec \"$@\" < \"$TRACTOR_TOOL_STDIN_FILE\"", "_", executable | args],
         options
       )}
    after
      File.rm(stdin_file)
    end
  end

  defp resolve_cwd(nil, run_dir), do: run_dir

  defp resolve_cwd(cwd, run_dir) do
    if Path.type(cwd) == :absolute, do: cwd, else: Path.expand(cwd, run_dir)
  end

  defp resolve_executable(nil, _cwd), do: {:error, {:tool_not_found, nil}}

  defp resolve_executable(binary, cwd) do
    cond do
      String.contains?(binary, "/") ->
        expanded = if(Path.type(binary) == :absolute, do: binary, else: Path.expand(binary, cwd))
        if File.exists?(expanded), do: {:ok, expanded}, else: {:error, {:tool_not_found, binary}}

      executable = System.find_executable(binary) ->
        {:ok, executable}

      true ->
        {:error, {:tool_not_found, binary}}
    end
  end

  defp write_command_artifact(run_dir, node_id, attempt, artifact) do
    path = Path.join([run_dir, node_id, "attempt-#{attempt}", "command.json"])
    Paths.atomic_write!(path, Jason.encode_to_iodata!(artifact, pretty: true))
  end
end

defimpl Collectable, for: Tractor.Handler.Tool.OutputCapture do
  def into(capture) do
    collector = fn
      state, {:cont, chunk} ->
        Tractor.Handler.Tool.OutputCapture.push(state, IO.iodata_to_binary(chunk))

      state, :done ->
        state

      _state, :halt ->
        :ok
    end

    {capture, collector}
  end
end
