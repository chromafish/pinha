defmodule PinhaWeb.IntegrationControllerTest do
  @moduledoc "Where a provider comes back to: the callback and the webhook."

  use PinhaWeb.ConnCase, async: false
  use Oban.Testing, repo: Pinha.Repo

  import Pinha.ProvidersFixtures

  alias Pinha.Providers
  alias Pinha.Providers.Authorizations
  alias Pinha.Providers.GitHub
  alias Pinha.Providers.GitHub.Config
  alias Pinha.Providers.LinkHandler

  @delivery ~s({"action":"deleted","installation":{"id":99}})

  describe "POST /integrations/github/webhook" do
    test "accepts a verified delivery and hands each subscriber its own job" do
      conn = deliver(@delivery, signature(@delivery), "d-1")

      assert conn.status == 202

      jobs = all_enqueued(worker: Providers.EventWorker)
      assert length(jobs) == length(Providers.subscribers())

      assert Enum.map(jobs, & &1.args["subscriber"]) |> Enum.sort() ==
               Providers.subscribers() |> Enum.map(&inspect/1) |> Enum.sort()

      assert Enum.all?(jobs, &(&1.args["event"]["type"] == "installation_removed"))
    end

    test "ignores a delivery it has already seen" do
      assert deliver(@delivery, signature(@delivery), "d-1").status == 202
      assert deliver(@delivery, signature(@delivery), "d-1").status == 200

      assert length(all_enqueued(worker: Providers.EventWorker)) ==
               length(Providers.subscribers())
    end

    test "refuses a delivery whose signature does not match the body" do
      assert deliver(@delivery, signature("something else"), "d-2").status == 401
      assert deliver(@delivery, "sha256=deadbeef", "d-3").status == 401
      assert deliver(@delivery, nil, "d-4").status == 401

      assert all_enqueued(worker: Providers.EventWorker) == []
    end

    test "answers nothing for a provider that is not configured" do
      put_github_env(webhook_secret: nil)

      assert deliver(@delivery, signature(@delivery), "d-5").status == 404
    end
  end

  describe "GET /integrations/github/callback" do
    setup %{user: user} do
      stub_github(%{
        {"POST", "/login/oauth/access_token"} => %{"access_token" => "gho_usertoken"},
        {"GET", "/user"} => %{"id" => 4711, "login" => "octo"},
        {"DELETE", "/applications/Iv1.testclient/token"} => &Plug.Conn.send_resp(&1, 204, "")
      })

      {:ok, url} =
        Authorizations.start(user, GitHub, LinkHandler, %{"return_to" => "/settings"})

      %{state: URI.decode_query(URI.parse(url).query)["state"]}
    end

    test "links the account the user authorized as", %{conn: conn, user: user, state: state} do
      conn = get(conn, "/integrations/github/callback?code=abc&state=#{state}")

      assert redirected_to(conn) == "/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Linked GitHub account octo"

      assert %{login: "octo", external_id: "4711"} = Providers.Accounts.get(user, "github")
    end

    test "refuses a state another user started", %{conn: conn, state: state} do
      other = user_fixture()
      conn = conn |> recycle() |> log_in_user(other)

      conn = get(conn, "/integrations/github/callback?code=abc&state=#{state}")

      assert conn.status == 400
      assert Providers.Accounts.get(other, "github") == nil
    end

    test "says so when the user declined", %{conn: conn, state: state} do
      conn = get(conn, "/integrations/github/callback?error=access_denied&state=#{state}")

      assert redirected_to(conn) == "/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "declined"
    end

    test "a signed-out browser is sent to sign in" do
      conn = get(build_conn(), "/integrations/github/callback?code=abc&state=whatever")

      assert redirected_to(conn) == "/signin"
    end
  end

  defp deliver(body, signature, delivery_id) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", "installation")
    |> put_req_header("x-github-delivery", delivery_id)
    |> then(fn conn ->
      if signature, do: put_req_header(conn, "x-hub-signature-256", signature), else: conn
    end)
    |> post("/integrations/github/webhook", body)
  end

  defp signature(body) do
    "sha256=" <>
      (:hmac
       |> :crypto.mac(:sha256, Config.webhook_secret(), body)
       |> Base.encode16(case: :lower))
  end
end
