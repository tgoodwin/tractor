defmodule TractorWeb.ErrorController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]

  def not_found(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "not found")
  end
end
