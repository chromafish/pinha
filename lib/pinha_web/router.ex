defmodule PinhaWeb.Router do
  use PinhaWeb, :router

  import PinhaWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_current_user
    plug :protect_from_forgery
    plug :put_root_layout, html: {PinhaWeb.Layouts, :root}
    plug :put_secure_browser_headers
  end

  pipeline :signed_in do
    plug :require_authenticated_user
  end

  # The WebAuthn ceremonies answer our own pages in JSON, so they carry the
  # session cookie and a CSRF token like any other browser write.
  pipeline :ceremony do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_current_user
    plug :protect_from_forgery
  end

  # Repository management answers both browsers and machines: a signed-in form
  # or a token over HTTP Basic. Only the cookie-carrying kind needs a CSRF
  # token, since a token request has no ambient credential to forge with.
  pipeline :management do
    plug :accepts, ["json", "html"]
    plug :fetch_session
    plug :fetch_current_user
    plug :require_user_or_token
    plug :maybe_protect_from_forgery
    plug :put_root_layout, html: {PinhaWeb.Layouts, :root}
    plug :put_secure_browser_headers
  end

  # Git clients negotiate nothing and hold no cookie: these routes speak the
  # smart HTTP protocol and authenticate with a token over HTTP Basic.
  pipeline :git do
    plug :fetch_session
    plug :fetch_current_user
    plug :require_user_for_git
  end

  scope "/", PinhaWeb do
    get "/metrics", MetricsController, :index
  end

  # The sign-in surface, the only part of the server a signed-out request
  # reaches.
  scope "/", PinhaWeb do
    pipe_through :browser

    get "/signup", AuthController, :new_signup
    get "/signin", AuthController, :new_session
  end

  scope "/", PinhaWeb do
    pipe_through :ceremony

    post "/signup/challenge", AuthController, :signup_challenge
    post "/signup", AuthController, :signup
    post "/signin/challenge", AuthController, :signin_challenge
    post "/signin", AuthController, :signin
  end

  scope "/", PinhaWeb do
    pipe_through [:ceremony, :signed_in]

    post "/settings/passkeys/challenge", SettingsController, :passkey_challenge
    post "/settings/passkeys", SettingsController, :add_passkey
  end

  scope "/", PinhaWeb do
    pipe_through [:browser, :signed_in]

    get "/settings", SettingsController, :show
    post "/settings/tokens", SettingsController, :create_token
    post "/settings/ssh-keys", SettingsController, :create_ssh_key
    delete "/settings/ssh-keys/:id", SettingsController, :delete_ssh_key
    post "/settings/invites", SettingsController, :create_invite
    delete "/settings/invites/:id", SettingsController, :delete_invite
    delete "/settings/tokens/:id", SettingsController, :delete_token
    delete "/settings/passkeys/:id", SettingsController, :delete_credential
    delete "/signout", AuthController, :delete
  end

  scope "/", PinhaWeb do
    pipe_through :management

    get "/", RepoController, :index
    post "/repos", RepoController, :create
    delete "/:repo", RepoController, :delete
  end

  scope "/", PinhaWeb do
    pipe_through :git

    get "/:repo/info/refs", GitHttpController, :info_refs
    post "/:repo/git-upload-pack", GitHttpController, :upload_pack
    post "/:repo/git-receive-pack", GitHttpController, :receive_pack
  end

  scope "/", PinhaWeb do
    pipe_through [:browser, :signed_in]

    post "/:repo/owner", RepoController, :set_owner
    get "/:repo", RepoController, :show
    get "/:repo/tree", BrowseController, :tree
    get "/:repo/tree/:rev", BrowseController, :tree
    get "/:repo/tree/:rev/*path", BrowseController, :tree
    get "/:repo/raw/:rev/*path", BrowseController, :raw
    get "/:repo/commit/:id", BrowseController, :commit
  end
end
