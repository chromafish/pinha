defmodule PinhaWeb.Router do
  use PinhaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {PinhaWeb.Layouts, :root}
    plug :put_secure_browser_headers
  end

  # Repository management answers both browsers and machines. There is no
  # authentication in v0.1, so there is no session to protect and no CSRF
  # token to check.
  pipeline :management do
    plug :accepts, ["json", "html"]
    plug :put_root_layout, html: {PinhaWeb.Layouts, :root}
    plug :put_secure_browser_headers
  end

  scope "/", PinhaWeb do
    get "/metrics", MetricsController, :index
  end

  scope "/", PinhaWeb do
    pipe_through :management

    get "/", RepoController, :index
    post "/repos", RepoController, :create
    delete "/:repo", RepoController, :delete
  end

  # Git clients negotiate nothing: these routes speak the smart HTTP protocol
  # and bypass Phoenix content negotiation.
  scope "/", PinhaWeb do
    get "/:repo/info/refs", GitHttpController, :info_refs
    post "/:repo/git-upload-pack", GitHttpController, :upload_pack
    post "/:repo/git-receive-pack", GitHttpController, :receive_pack
  end

  scope "/", PinhaWeb do
    pipe_through :browser

    get "/:repo", RepoController, :show
    get "/:repo/tree", BrowseController, :tree
    get "/:repo/tree/:rev", BrowseController, :tree
    get "/:repo/tree/:rev/*path", BrowseController, :tree
    get "/:repo/raw/:rev/*path", BrowseController, :raw
    get "/:repo/commit/:id", BrowseController, :commit
  end
end
