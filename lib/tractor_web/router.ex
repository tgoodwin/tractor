defmodule TractorWeb.Router do
  @moduledoc false

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {TractorWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/dev", TractorWeb do
    pipe_through(:api)

    post("/reap", DevController, :reap)
    post("/stop/:run_id", DevController, :stop)
    post("/stop-all", DevController, :stop_all)
  end

  scope "/", TractorWeb do
    pipe_through(:browser)

    live("/runs/:run_id", RunLive.Show)

    # credo:disable-for-next-line Credo.Check.Design.TagTODO
    # TODO(sprint-3): run history browser
    match(:*, "/*path", ErrorController, :not_found)
  end
end
