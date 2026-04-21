defmodule TractorWeb.DevController do
  @moduledoc """
  Dev-only endpoint to launch pipelines inside the Phoenix BEAM. Necessary for
  `wait.human` testing because `Tractor.Run.submit_wait_choice/3` dispatches
  via a local `Tractor.RunRegistry` lookup — the observer can only drive a run
  that's running in the same OTP node.

  `POST /dev/reap?path=examples/...`
  """

  use Phoenix.Controller, formats: [:json, :html]

  alias Tractor.{DotParser, Run, Validator}

  def reap(conn, %{"path" => path}) do
    with :ok <- ensure_file(path),
         {:ok, pipeline} <- DotParser.parse_file(path),
         :ok <- Validator.validate(pipeline),
         {:ok, run_id} <- Run.start(pipeline) do
      url = "#{base_url(conn)}/runs/#{run_id}"
      json(conn, %{run_id: run_id, url: url, path: path})
    else
      {:missing_file, p} ->
        conn |> put_status(404) |> json(%{error: "file not found", path: p})

      {:error, diagnostics} when is_list(diagnostics) ->
        messages = Enum.map(diagnostics, & &1.message)
        conn |> put_status(422) |> json(%{error: "validation failed", messages: messages})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def reap(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "missing ?path=<dot-file> query param"})
  end

  def stop(conn, %{"run_id" => run_id}) do
    case Registry.lookup(Tractor.RunRegistry, run_id) do
      [{pid, _}] ->
        :ok = DynamicSupervisor.terminate_child(Tractor.RunSup, pid)
        json(conn, %{stopped: run_id})

      [] ->
        conn |> put_status(404) |> json(%{error: "run not found in registry", run_id: run_id})
    end
  end

  def stop_all(conn, _params) do
    children = DynamicSupervisor.which_children(Tractor.RunSup)

    Enum.each(children, fn {_id, pid, _type, _mods} ->
      DynamicSupervisor.terminate_child(Tractor.RunSup, pid)
    end)

    json(conn, %{stopped: length(children)})
  end

  defp ensure_file(path), do: if(File.regular?(path), do: :ok, else: {:missing_file, path})

  defp base_url(conn) do
    "#{conn.scheme}://#{conn.host}:#{conn.port}"
  end
end
