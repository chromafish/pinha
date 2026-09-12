defmodule Pinha.Providers.GitHubTest do
  @moduledoc "The app's own credentials, delivery verification, and events."

  use Pinha.DataCase, async: false

  import Pinha.ProvidersFixtures

  alias Pinha.Providers.Error
  alias Pinha.Providers.GitHub
  alias Pinha.Providers.GitHub.Client
  alias Pinha.Providers.GitHub.Config
  alias Pinha.Providers.Secret

  describe "the app JWT" do
    test "is signed RS256 with the app's key and lasts ten minutes" do
      now = 1_800_000_000
      assert {:ok, %Secret{} = jwt} = Client.app_jwt(now)

      [header, claims, signature] = jwt |> Secret.reveal() |> String.split(".")
      assert %{"alg" => "RS256", "typ" => "JWT"} = decode(header)
      assert %{"iat" => iat, "exp" => exp, "iss" => "1"} = decode(claims)
      assert iat == now - 60
      assert exp == now + 540

      assert :public_key.verify(
               header <> "." <> claims,
               :sha256,
               Base.url_decode64!(signature, padding: false),
               public_key()
             )
    end

    test "a key the operator got wrong is an error, not a crash" do
      put_github_env(private_key: "not a pem")
      assert {:error, %Error{kind: :transient}} = Client.app_jwt()
    end
  end

  describe "configured?/0" do
    test "needs every setting, and without them there are no capabilities" do
      assert GitHub.configured?()
      assert Pinha.Providers.configured() == [GitHub]

      put_github_env(webhook_secret: nil)

      refute GitHub.configured?()
      assert Pinha.Providers.configured() == []
      assert Pinha.Providers.capability("github", Pinha.Mirroring.Capability) == :error
      refute Pinha.Mirroring.available?()
    end
  end

  describe "installation tokens" do
    test "ask only for the one target and the permissions a push needs" do
      stub_github(%{
        {"POST", "/app/installations/99/access_tokens"} => fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(self(), {:token_request, Jason.decode!(body)})
          Req.Test.json(conn, %{"token" => "ghs_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"})
        end
      })

      assert {:ok, %Secret{}} =
               Client.installation_token("99", ["1234"], %{
                 "contents" => "write",
                 "workflows" => "write"
               })

      assert_received {:token_request, request}
      assert request["repository_ids"] == [1234]
      assert request["permissions"] == %{"contents" => "write", "workflows" => "write"}
    end

    test "classify a removed, suspended, or out-of-reach installation as terminal" do
      cases = [
        {404, "Not Found", :installation_removed},
        {403, "This installation has been suspended", :installation_suspended},
        {422, "There is at least one repository that does not exist", :target_unreachable}
      ]

      for {status, message, reason} <- cases do
        stub_github(%{
          {"POST", "/app/installations/99/access_tokens"} =>
            &(&1 |> Plug.Conn.put_status(status) |> Req.Test.json(%{"message" => message}))
        })

        assert {:error, %Error{kind: :terminal, reason: ^reason, message: got}} =
                 Client.installation_token("99", ["1234"], %{})

        assert got =~ message
      end
    end

    test "a rate limit and a server error stay transient" do
      stub_github(%{
        {"POST", "/app/installations/99/access_tokens"} =>
          &(&1
            |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"message" => "API rate limit exceeded"}))
      })

      assert {:error, %Error{kind: :transient, message: message}} =
               Client.installation_token("99", ["1234"], %{})

      assert message =~ "rate limited"
    end
  end

  describe "verify_delivery/2" do
    test "accepts a signature over the exact body and refuses everything else" do
      body = ~s({"action":"deleted"})
      headers = %{"x-github-delivery" => "d-1", "x-hub-signature-256" => signature(body)}

      assert GitHub.verify_delivery(headers, body) == {:ok, "d-1"}

      assert GitHub.verify_delivery(headers, body <> " ") == {:error, :invalid_signature}

      assert GitHub.verify_delivery(%{headers | "x-hub-signature-256" => "sha256=00"}, body) ==
               {:error, :invalid_signature}

      assert GitHub.verify_delivery(Map.delete(headers, "x-hub-signature-256"), body) ==
               {:error, :invalid_signature}

      assert GitHub.verify_delivery(Map.delete(headers, "x-github-delivery"), body) ==
               {:error, :invalid_signature}
    end
  end

  describe "events/2" do
    test "names what a delivery means, and ignores the rest" do
      assert GitHub.events(%{"x-github-event" => "installation"}, %{
               "action" => "deleted",
               "installation" => %{"id" => 99}
             }) == [%{"type" => "installation_removed", "installation_id" => "99"}]

      assert GitHub.events(%{"x-github-event" => "installation_repositories"}, %{
               "action" => "removed",
               "installation" => %{"id" => 99},
               "repositories_removed" => [%{"id" => 7}]
             }) == [
               %{
                 "type" => "repositories_removed",
                 "installation_id" => "99",
                 "repository_ids" => ["7"]
               }
             ]

      assert GitHub.events(%{"x-github-event" => "repository"}, %{
               "action" => "renamed",
               "repository" => %{
                 "id" => 7,
                 "full_name" => "octo/new",
                 "html_url" => "https://github.test/octo/new"
               }
             }) == [
               %{
                 "type" => "repository_renamed",
                 "repository_id" => "7",
                 "name" => "octo/new",
                 "url" => "https://github.test/octo/new"
               }
             ]

      assert GitHub.events(%{"x-github-event" => "push"}, %{"action" => "anything"}) == []
      assert GitHub.events(%{"x-github-event" => "installation"}, %{"action" => "created"}) == []
    end
  end

  defp signature(body) do
    "sha256=" <>
      (:hmac
       |> :crypto.mac(:sha256, Config.webhook_secret(), body)
       |> Base.encode16(case: :lower))
  end

  defp decode(segment), do: segment |> Base.url_decode64!(padding: false) |> Jason.decode!()

  defp public_key do
    [entry] = :public_key.pem_decode(Config.private_key())
    key = :public_key.pem_entry_decode(entry)
    {:RSAPublicKey, elem(key, 2), elem(key, 3)}
  end
end
