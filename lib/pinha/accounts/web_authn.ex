defmodule Pinha.Accounts.WebAuthn do
  @moduledoc """
  The two WebAuthn ceremonies, as the browser and `wax_` need them.

  The relying party ID is the host of the configured public base URL, so a
  passkey is bound to the name the operator publishes. Browsers refuse the API
  outside a secure context, which makes HTTPS a deployment requirement and
  `localhost` the reason development works without it.
  """

  alias Pinha.Accounts.Credential
  alias Pinha.Config

  @rp_name "pinha"
  # ES256 and RS256: what every passkey implementation in the field signs with.
  @algorithms [-7, -257]

  @doc "A challenge for registering a passkey, with the options the browser expects."
  @spec registration(binary(), String.t(), [binary()]) :: {map(), Wax.Challenge.t()}
  def registration(handle, email, exclude \\ []) do
    challenge =
      Wax.new_registration_challenge(origin: origin(), rp_id: :auto, attestation: "none")

    options = %{
      challenge: encode(challenge.bytes),
      rp: %{id: challenge.rp_id, name: @rp_name},
      user: %{id: encode(handle), name: email, displayName: email},
      pubKeyCredParams: Enum.map(@algorithms, &%{type: "public-key", alg: &1}),
      timeout: challenge.timeout * 1000,
      attestation: "none",
      excludeCredentials: Enum.map(exclude, &descriptor/1),
      authenticatorSelection: %{
        residentKey: "required",
        requireResidentKey: true,
        userVerification: "preferred"
      }
    }

    {options, challenge}
  end

  @doc """
  Verifies a registration response, returning what the credential row needs.

  `wax_` checks the challenge, origin, relying party, and attestation; what
  comes back here is only the parts worth storing.
  """
  @spec verify_registration(map(), Wax.Challenge.t()) :: {:ok, map()} | {:error, term()}
  def verify_registration(%{"attestationObject" => object, "clientDataJSON" => client_data}, chal) do
    with {:ok, object} <- decode(object),
         {:ok, client_data} <- decode(client_data),
         {:ok, {auth_data, _attestation}} <- Wax.register(object, client_data, chal) do
      attested = auth_data.attested_credential_data

      {:ok,
       %{
         credential_id: attested.credential_id,
         public_key: Credential.encode_key(attested.credential_public_key),
         aaguid: Wax.AuthenticatorData.get_aaguid(auth_data),
         sign_count: auth_data.sign_count
       }}
    end
  end

  def verify_registration(_params, _challenge), do: {:error, :malformed}

  @doc "A challenge for signing in with any discoverable passkey."
  @spec authentication() :: {map(), Wax.Challenge.t()}
  def authentication do
    challenge = Wax.new_authentication_challenge(origin: origin(), rp_id: :auto)

    options = %{
      challenge: encode(challenge.bytes),
      rpId: challenge.rp_id,
      timeout: challenge.timeout * 1000,
      userVerification: "preferred"
    }

    {options, challenge}
  end

  @doc """
  Verifies an assertion against the keys the named user holds.

  The response carries the user handle the authenticator stored, which is how
  a sign-in that never asked for a username knows whose keys to check.
  """
  @spec verify_authentication(map(), Wax.Challenge.t(), [{binary(), map()}]) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def verify_authentication(params, challenge, credentials) do
    %{
      "id" => raw_id,
      "authenticatorData" => auth_data,
      "signature" => signature,
      "clientDataJSON" => client_data
    } = params

    with {:ok, credential_id} <- decode(raw_id),
         {:ok, auth_data} <- decode(auth_data),
         {:ok, signature} <- decode(signature),
         {:ok, client_data} <- decode(client_data),
         {:ok, data} <-
           Wax.authenticate(
             credential_id,
             auth_data,
             signature,
             client_data,
             challenge,
             credentials
           ) do
      {:ok, credential_id, data.sign_count}
    end
  rescue
    MatchError -> {:error, :malformed}
  end

  @doc "The user handle a sign-in response carries, decoded."
  @spec user_handle(map()) :: {:ok, binary()} | {:error, term()}
  def user_handle(%{"userHandle" => handle}) when is_binary(handle), do: decode(handle)
  def user_handle(_params), do: {:error, :no_user_handle}

  @doc "Base64url without padding, which is how WebAuthn moves bytes through JSON."
  @spec encode(binary()) :: String.t()
  def encode(bytes), do: Base.url_encode64(bytes, padding: false)

  @spec decode(String.t()) :: {:ok, binary()} | {:error, :malformed}
  def decode(text) when is_binary(text) do
    case Base.url_decode64(text, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :malformed}
    end
  end

  def decode(_), do: {:error, :malformed}

  defp descriptor(credential_id), do: %{type: "public-key", id: encode(credential_id)}

  defp origin, do: Config.base_url()
end
