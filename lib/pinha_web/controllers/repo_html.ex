defmodule PinhaWeb.RepoHTML do
  @moduledoc "Repository list and summary templates."

  use PinhaWeb, :html

  alias Pinha.Mirroring.Mirror

  embed_templates "repo_html/*"

  attr :kind, :atom, required: true, values: [:git, :jj, :jj_via_git]
  attr :model, :atom, required: true, values: [:git, :jj]

  def repository_kind_badge(assigns) do
    assigns =
      assigns
      |> assign(:jj_history, jj_history?(assigns.kind))
      |> assign(:label, repository_kind_label(assigns.kind))
      |> assign(:title, repository_kind_title(assigns.kind, assigns.model))

    ~H"""
    <span
      class={["repository-kind", @jj_history && "repository-kind-jj"]}
      data-repository-kind={if(@jj_history, do: "jujutsu", else: "git")}
      data-repository-model={Atom.to_string(@model)}
      title={@title}
    >
      {@label}
    </span>
    """
  end

  def jj_history?(kind), do: kind in [:jj, :jj_via_git]

  @doc "What a mirror's state means, in words."
  def mirror_state_label(%{state: "active"}), do: "active"
  def mirror_state_label(%{state: "awaiting_access"}), do: "awaiting access"

  def mirror_state_label(%{state: "disabled"} = mirror),
    do: "disabled — " <> mirror_reason_label(mirror.disabled_reason)

  @doc "What disabled a mirror, in words."
  def mirror_reason_label("user"), do: "switched off here"
  def mirror_reason_label("repository_gone"), do: "the repository is gone"
  def mirror_reason_label("owner_changed"), do: "the repository changed owner"
  def mirror_reason_label("account_unlinked"), do: "the connecting account was unlinked"
  def mirror_reason_label("access_lost"), do: "the connecting user lost write access"
  def mirror_reason_label("installation_removed"), do: "the app was removed"
  def mirror_reason_label("installation_suspended"), do: "the app is suspended"
  def mirror_reason_label("target_unreachable"), do: "the target is out of reach"
  def mirror_reason_label("push_rejected"), do: "the provider refused the push"
  def mirror_reason_label(_reason), do: "unknown"

  defp repository_kind_label(:git), do: "Git"
  defp repository_kind_label(:jj), do: "Jujutsu"
  defp repository_kind_label(:jj_via_git), do: "Jujutsu via Git"

  defp repository_kind_title(:git, :git), do: "Plain Git repository and history"

  defp repository_kind_title(:jj, :jj),
    do: "Native Jujutsu repository with Git-compatible transport"

  defp repository_kind_title(:jj_via_git, :git),
    do: "Jujutsu change history detected in a Git repository"
end
