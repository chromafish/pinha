defmodule PinhaWeb.Layouts do
  @moduledoc """
  The console frame from the chromafish "consoles" layout reference.

  The frame does not scroll: a header line naming the place being read sits at
  the top edge, one region scrolls between it and the bottom edge, and a
  control bar plus a single-line status bar are pinned below. Every shortcut
  the keyboard layer implements is printed in the status bar.
  """

  use PinhaWeb, :html

  embed_templates "layouts/*"

  attr :title, :string, default: nil, doc: "the place being read, e.g. \"commit ab12cd3\""
  attr :count, :string, default: nil, doc: "right-hand reading on the header line"
  attr :up, :string, default: nil, doc: "path the `u` key walks up to"
  attr :status, :string, default: nil, doc: "extra reading on the status bar"
  attr :current_user, :map, default: nil, doc: "who is signed in, if anyone"
  attr :flash, :map, default: %{}, doc: "what the last request wants to say"

  slot :inner_block, required: true
  slot :trail, doc: "link trail shown on the header line in place of the title"
  slot :badge, doc: "compact context label shown beside the title or trail"
  slot :controls, doc: "the control bar pinned above the status bar"

  def app(assigns) do
    ~H"""
    <div class="frame" data-up={@up}>
      <header class="frame-head">
        <a class="wordmark" href="/">pinha</a>

        <nav :if={@trail != []} class="trail">{render_slot(@trail)}</nav>
        <span :if={@trail == [] and @title} class="where">{@title}</span>
        <span :if={@badge != []} class="frame-badge">{render_slot(@badge)}</span>

        <span :if={@count} class="reading">{@count}</span>

        <a :if={@current_user} class="who" href="/settings">{@current_user.username}</a>
      </header>

      <div class="region">
        <div :if={notices(@flash) != []} class="notices">
          <p
            :for={{level, message} <- notices(@flash)}
            class={["notice", "notice-" <> level]}
            role="alert"
          >
            {message}
          </p>
        </div>

        {render_slot(@inner_block)}
      </div>

      <div :if={@controls != []} class="controls">
        {render_slot(@controls)}
      </div>

      <footer class="status">
        <span><kbd>j</kbd>/<kbd>k</kbd> move</span>
        <span><kbd>enter</kbd> open</span>
        <span :if={@up}><kbd>u</kbd> up</span>
        <span :if={@status}>{@status}</span>
      </footer>
    </div>
    """
  end

  # What a redirect left behind, in the order a reader wants it: the failure
  # first, since that is the one that needs doing something about.
  defp notices(flash) do
    for level <- ["error", "info"],
        message = Phoenix.Flash.get(flash, level),
        do: {level, message}
  end
end
