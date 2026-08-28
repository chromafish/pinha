defmodule PinhaWeb.BrowseHTML do
  @moduledoc "Tree, blob, commit, and change-id disambiguation templates."

  use PinhaWeb, :html

  embed_templates "browse_html/*"

  attr :repo, :map, required: true
  attr :target, :map, required: true
  attr :path, :string, default: ""

  @doc "Link trail: repo, revision, and the path segments leading to the current one."
  def crumbs(assigns) do
    ~H"""
    <a href={repo_path(@repo.name)}>{@repo.name}</a>
    <span class="sep">/</span>
    <a href={tree_path(@repo.name, @target.name)}>{@target.name}</a>
    <span :for={{name, full} <- breadcrumbs(@path)}>
      <span class="sep">/</span>
      <a href={tree_path(@repo.name, @target.name, full)}>{name}</a>
    </span>
    """
  end

  attr :target, :map, required: true

  @doc "How the revision in the URL resolved, and the commit it points at."
  def target_info(assigns) do
    ~H"""
    <span class="field-set">
      <span class="field"><span class="key">{kind(@target.kind)}</span>{@target.name}</span>
      <span class="field">
        <span class="key">at</span><span class="id">{short(@target.id)}</span>
      </span>
      <span :if={@target.change_id} class="field">
        <span class="key">change</span><span class="change-id">{short(@target.change_id)}</span>
      </span>
    </span>
    """
  end

  defp kind(:commit), do: "commit"
  defp kind(:branch), do: "branch"
  defp kind(:tag), do: "tag"
  defp kind(:change_id), do: "change"
end
