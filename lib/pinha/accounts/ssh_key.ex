defmodule Pinha.Accounts.SshKey do
  @moduledoc """
  What git presents over SSH.

  A public key pasted into the UI in `authorized_keys` form. The stored
  fingerprint is the SHA-256 of the key blob, the same digest `ssh-keygen -lf`
  prints, and it is unique across every user: a key names one person, and
  authenticating a connection is one indexed read of it.

  The key itself is kept in its canonical one-line form so the settings page
  can show what was registered, but nothing is ever verified against that
  text: verification compares fingerprints of decoded keys.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Pinha.Accounts.User

  @type t :: %__MODULE__{}

  # Ed25519 and the NIST curves, plus RSA at a size worth accepting. DSA is
  # absent on purpose: 1024-bit signatures are not worth a push.
  @algorithms ~w(
    ssh-ed25519
    ecdsa-sha2-nistp256
    ecdsa-sha2-nistp384
    ecdsa-sha2-nistp521
    ssh-rsa
    rsa-sha2-256
    rsa-sha2-512
  )
  @min_rsa_bits 2048

  schema "user_ssh_keys" do
    field(:fingerprint, :binary)
    field(:public_key, :string)
    field(:algorithm, :string)
    field(:label, :string)
    field(:last_used_at, :utc_datetime)

    belongs_to(:user, User)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for a key that has already been parsed."
  def changeset(key, attrs) do
    key
    |> cast(attrs, [:fingerprint, :public_key, :algorithm, :label, :user_id])
    |> validate_required([:fingerprint, :public_key, :algorithm, :label, :user_id])
    |> validate_length(:label, min: 1, max: 80)
    |> unique_constraint(:fingerprint)
  end

  @doc """
  Parses one `authorized_keys` line into the attributes to store.

  The comment becomes the label when the form leaves it blank, which is what
  makes pasting a key and pressing the button do the obvious thing.
  """
  @spec parse(String.t(), String.t() | nil) ::
          {:ok, map()}
          | {:error, :unreadable | :unsupported_algorithm | :weak_key}
  def parse(text, label \\ nil) when is_binary(text) do
    with {:ok, key, comment} <- decode(text),
         {:ok, algorithm, blob} <- canonical(key),
         :ok <- acceptable(algorithm, key) do
      {:ok,
       %{
         fingerprint: :crypto.hash(:sha256, blob),
         public_key: algorithm <> " " <> Base.encode64(blob),
         algorithm: algorithm,
         label: label(label, comment)
       }}
    end
  end

  @doc "The SHA-256 fingerprint of a key `ssh` handed us, for the lookup."
  @spec fingerprint(term()) :: {:ok, binary()} | :error
  def fingerprint(key) do
    case canonical(key) do
      {:ok, _algorithm, blob} -> {:ok, :crypto.hash(:sha256, blob)}
      _ -> :error
    end
  end

  @doc "`SHA256:...`, the form `ssh-keygen` prints and a user recognizes."
  @spec format_fingerprint(binary()) :: String.t()
  def format_fingerprint(fingerprint),
    do: "SHA256:" <> Base.encode64(fingerprint, padding: false)

  # A pasted key may arrive with trailing whitespace, CRLFs from a Windows
  # editor, or several lines; exactly one key is a key.
  defp decode(text) do
    text = text |> String.replace("\r\n", "\n") |> String.trim()

    case safe_decode(text <> "\n") do
      [{key, attrs}] -> {:ok, key, attrs[:comment]}
      _ -> {:error, :unreadable}
    end
  end

  defp safe_decode(text) do
    :ssh_file.decode(text, :auth_keys)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Re-encoding drops the comment and any options, so the fingerprint depends
  # on the key alone and the same key pasted twice collides whatever trails it.
  defp canonical(key) do
    case safe_encode(key) do
      line when is_binary(line) ->
        case String.split(String.trim(line), " ", parts: 3) do
          [algorithm, body | _] ->
            case Base.decode64(body) do
              {:ok, blob} -> {:ok, algorithm, blob}
              :error -> {:error, :unreadable}
            end

          _ ->
            {:error, :unreadable}
        end

      _ ->
        {:error, :unreadable}
    end
  end

  defp safe_encode(key) do
    :ssh_file.encode([{key, []}], :auth_keys)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp acceptable(algorithm, key) do
    cond do
      algorithm not in @algorithms -> {:error, :unsupported_algorithm}
      rsa_bits(key) in 1..(@min_rsa_bits - 1) -> {:error, :weak_key}
      true -> :ok
    end
  end

  defp rsa_bits({:RSAPublicKey, modulus, _exponent}),
    do: byte_size(:binary.encode_unsigned(modulus)) * 8

  defp rsa_bits(_), do: 0

  defp label(given, comment) do
    case given |> to_string() |> String.trim() do
      "" -> comment |> to_string() |> String.trim() |> default_label()
      text -> String.slice(text, 0, 80)
    end
  end

  defp default_label(""), do: "ssh key"
  defp default_label(comment), do: String.slice(comment, 0, 80)
end
