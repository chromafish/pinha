defmodule Pinha.Providers.SecretTest do
  @moduledoc "The credential rules a secret and the scrubber carry."

  use ExUnit.Case, async: true

  alias Pinha.Providers.Scrub
  alias Pinha.Providers.Secret

  @token "ghs_0123456789abcdefghijklmnopqrstuvwxyz"

  test "inspect never shows the credential" do
    secret = Secret.new(@token)

    assert inspect(secret) == "#Pinha.Providers.Secret<redacted>"
    refute inspect(%{token: secret}) =~ @token
    refute inspect([secret: secret], limit: :infinity) =~ @token
    assert Secret.reveal(secret) == @token
  end

  test "a secret cannot be encoded into a job's arguments" do
    assert_raise Protocol.UndefinedError, fn -> Jason.encode!(%{token: Secret.new(@token)}) end
  end

  describe "scrub/2" do
    test "removes known secrets, in plain and in basic form" do
      secret = Secret.new(@token)
      header = "Authorization: Basic " <> Base.encode64("x-access-token:" <> @token)

      scrubbed = Scrub.scrub("fatal: #{@token} rejected\n#{header}", [secret])

      refute scrubbed =~ @token
      refute scrubbed =~ Base.encode64("x-access-token:" <> @token)
      assert scrubbed =~ "rejected"
    end

    test "removes token-shaped strings it was never told about" do
      text = """
      remote: refused with ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      remote: and github_pat_11AAAAAAA0BBBBBBBBBB_cccccccccccccccccccccc
      authorization: bearer eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiIxIn0.c2ln
      fatal: could not read https://x-access-token:ghs_secretsecretsecret@github.com/o/r.git
      """

      scrubbed = Scrub.scrub(text)

      refute scrubbed =~ "ghp_"
      refute scrubbed =~ "github_pat_"
      refute scrubbed =~ "eyJ"
      refute scrubbed =~ "x-access-token:"
      assert scrubbed =~ "remote: refused with"
    end
  end
end
