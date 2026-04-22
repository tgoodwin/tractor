defmodule TractorWeb.HealthController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    json(conn, %{
      ok: true,
      version: tractor_version(),
      runs_dir: Tractor.Paths.runs_dir()
    })
  end

  defp tractor_version do
    case Application.spec(:tractor, :vsn) do
      nil -> "0.1.0"
      version -> to_string(version)
    end
  end
end
