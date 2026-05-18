defmodule TractorWeb.StaticPlug do
  @moduledoc """
  Serves assets from `TractorWeb.StaticAssets` (the compile-time bundle of
  `priv/static`). Replaces `Plug.Static`, which resolves `from:` relative to
  the runtime cwd and so 404s when `tractor` runs outside the repo.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["GET", "HEAD"] do
    case TractorWeb.StaticAssets.fetch(conn.request_path) do
      {:ok, body} ->
        conn
        |> put_resp_content_type(MIME.from_path(conn.request_path))
        |> put_resp_header("cache-control", "public, max-age=300")
        |> send_resp(200, body)
        |> halt()

      :error ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
