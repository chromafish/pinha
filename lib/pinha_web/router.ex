defmodule PinhaWeb.Router do
  use PinhaWeb, :router

  import PinhaWeb.UserAuth

  # Every page carries a CSRF token minted for the session that rendered it,
  # so a page that outlives its session is a page whose token is already
  # refused. `no-store` is what keeps a suspended tab out of the back/forward
  # cache: the default `max-age=0, must-revalidate` governs the HTTP cache
  # only, and Safari restores a killed tab from the page cache without asking.
  @no_store %{"cache-control" => "no-store"}

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :fetch_current_user
    plug :protect_from_forgery
    plug :put_root_layout, html: {PinhaWeb.Layouts, :root}
    plug :put_secure_browser_headers, @no_store
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
    plug :put_secure_browser_headers, @no_store
  end

  # A provider's webhook holds no session and answers no CSRF token: the
  # delivery is verified against the webhook secret instead, over its exact
  # bytes, which is why the parsers leave the body alone.
  pipeline :webhook do
    plug :accepts, ["json"]
  end

  # Git clients negotiate nothing and hold no cookie: these routes speak the
  # smart HTTP protocol and authenticate with a token over HTTP Basic.
  pipeline :git do
    plug :fetch_session
    plug :fetch_current_user
    plug :require_user_for_git
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
    patch "/settings/username", SettingsController, :update_username
    put "/settings/username", SettingsController, :update_username
    post "/settings/username", SettingsController, :update_username
    post "/settings/tokens", SettingsController, :create_token
    post "/settings/ssh-keys", SettingsController, :create_ssh_key
    delete "/settings/ssh-keys/:id", SettingsController, :delete_ssh_key
    post "/settings/providers/:provider", SettingsController, :connect_provider
    delete "/settings/providers/:provider", SettingsController, :disconnect_provider
    post "/settings/invites", SettingsController, :create_invite
    delete "/settings/invites/:id", SettingsController, :delete_invite
    delete "/settings/tokens/:id", SettingsController, :delete_token
    delete "/settings/passkeys/:id", SettingsController, :delete_credential
    delete "/signout", AuthController, :delete
  end

  scope "/integrations", PinhaWeb do
    pipe_through :webhook

    post "/:provider/webhook", IntegrationController, :webhook
  end

  scope "/integrations", PinhaWeb do
    pipe_through [:browser, :signed_in]

    get "/:provider/callback", IntegrationController, :callback
  end

  scope "/", PinhaWeb do
    pipe_through :management

    get "/", RepoController, :index
    post "/repos", RepoController, :create
  end

  scope "/r", PinhaWeb do
    pipe_through :management

    delete "/:repo", RepoController, :delete
  end

  scope "/r", PinhaWeb do
    pipe_through :git

    get "/:repo/info/refs", GitHttpController, :info_refs
    post "/:repo/git-upload-pack", GitHttpController, :upload_pack
    post "/:repo/git-receive-pack", GitHttpController, :receive_pack
  end

  scope "/r", PinhaWeb do
    pipe_through [:browser, :signed_in]

    post "/:repo/owner", RepoController, :set_owner
    post "/:repo/mirror", MirrorController, :connect
    post "/:repo/mirror/sync", MirrorController, :sync
    post "/:repo/mirror/enable", MirrorController, :enable
    post "/:repo/mirror/disable", MirrorController, :disable
    post "/:repo/mirror/check", MirrorController, :check
    delete "/:repo/mirror", MirrorController, :disconnect
    get "/:repo", RepoController, :show
    get "/:repo/tree", BrowseController, :tree
    get "/:repo/tree/:rev", BrowseController, :tree
    get "/:repo/tree/:rev/*path", BrowseController, :tree
    get "/:repo/raw/:rev/*path", BrowseController, :raw
    get "/:repo/commit/:id", BrowseController, :commit
  end
end
