defmodule PinhaWeb.RepoHTML do
  @moduledoc "Repository list and summary templates."

  use PinhaWeb, :html

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

  defp repository_kind_label(:git), do: "Git"
  defp repository_kind_label(:jj), do: "Jujutsu"
  defp repository_kind_label(:jj_via_git), do: "Jujutsu via Git"

  defp repository_kind_title(:git, :git), do: "Plain Git repository and history"

  defp repository_kind_title(:jj, :jj),
    do: "Native Jujutsu repository with Git-compatible transport"

  defp repository_kind_title(:jj_via_git, :git),
    do: "Jujutsu change history detected in a Git repository"
end
