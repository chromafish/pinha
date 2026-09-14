defmodule PinhaWeb.Markdown do
  @moduledoc """
  Markdown rendering for README files with sanitization and relative link resolution.
  """

  @doc """
  Renders `text` as sanitized HTML.

  For `:markdown`, the text is parsed with Earmark (GFM) and sanitized with
  `HtmlSanitizeEx.markdown_html/1`. For `:text`, it is escaped and wrapped in
  `<pre>`.

  Relative `href` and `src` attributes are rewritten against the current ref:

    * `href` -> `/r/<repo>/tree/<rev>/<path>`
    * `src`  -> `/r/<repo>/raw/<rev>/<path>`

  Absolute URLs (scheme, `//`, `#anchor`, `data:`, `mailto:`) are left alone.
  """
  @spec to_html(String.t(), :markdown | :text, String.t(), String.t(), String.t()) ::
          {:safe, String.t()} | String.t()
  def to_html(text, kind, repo_name, rev_name, dir \\ "")

  def to_html(text, :text, _repo, _rev, _dir) do
    escaped = text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    {:safe, "<pre class=\"readme-plain\">" <> escaped <> "</pre>"}
  end

  def to_html(text, :markdown, repo_name, rev_name, dir) do
    case Earmark.as_html(text, gfm: true, breaks: false) do
      {:ok, html, _} ->
        html =
          html |> HtmlSanitizeEx.markdown_html() |> rewrite_relative(repo_name, rev_name, dir)

        {:safe, html}

      {:error, html, _} ->
        html =
          html |> HtmlSanitizeEx.markdown_html() |> rewrite_relative(repo_name, rev_name, dir)

        {:safe, html}
    end
  end

  @doc false
  def rewrite_relative(html, repo_name, rev_name, dir) do
    html
    |> rewrite_hrefs(repo_name, rev_name, dir)
    |> rewrite_srcs(repo_name, rev_name, dir)
  end

  defp rewrite_hrefs(html, repo_name, rev_name, dir) do
    Regex.replace(~r/(<a\b[^>]*\bhref=")([^"]*)(")/i, html, fn full, prefix, url, suffix ->
      if relative_url?(url) do
        resolved = resolve_path(dir, url)
        prefix <> tree_url(repo_name, rev_name, resolved) <> suffix
      else
        full
      end
    end)
  end

  defp rewrite_srcs(html, repo_name, rev_name, dir) do
    Regex.replace(~r/(<img\b[^>]*\bsrc=")([^"]*)(")/i, html, fn full, prefix, url, suffix ->
      if relative_url?(url) do
        resolved = resolve_path(dir, url)
        prefix <> raw_url(repo_name, rev_name, resolved) <> suffix
      else
        full
      end
    end)
  end

  defp relative_url?(""), do: false

  defp relative_url?(url) do
    not Regex.match?(~r/\A(?:[a-zA-Z][a-zA-Z0-9+.\-]*:|\/\/|#|data:|mailto:)/, url)
  end

  defp resolve_path(base_dir, url) do
    {path_part, suffix} = split_suffix(url)

    normalized =
      cond do
        String.starts_with?(path_part, "/") ->
          path_part |> String.trim_leading("/") |> normalize_path()

        base_dir == "" ->
          normalize_path(path_part)

        true ->
          normalize_path(base_dir <> "/" <> path_part)
      end

    normalized <> suffix
  end

  defp split_suffix(url) do
    # Preserve fragment (#...) and query (?...) after the path
    case Regex.run(~r/^([^#?]*)([#?].*)?$/, url) do
      [_, path, nil] -> {path, ""}
      [_, path, suffix] -> {path, suffix}
      _ -> {url, ""}
    end
  end

  defp normalize_path(path) do
    parts = String.split(path, "/", trim: false)

    stack =
      Enum.reduce(parts, [], fn
        "", acc -> acc
        ".", acc -> acc
        "..", [] -> []
        "..", [_ | tail] -> tail
        part, acc -> [part | acc]
      end)

    stack |> Enum.reverse() |> Enum.join("/")
  end

  defp tree_url(repo_name, rev_name, path) do
    encoded_repo = URI.encode(repo_name, &URI.char_unreserved?/1)
    encoded_rev = URI.encode(rev_name, &URI.char_unreserved?/1)

    if path == "" do
      "/r/#{encoded_repo}/tree/#{encoded_rev}"
    else
      segments =
        path
        |> String.split("/", trim: true)
        |> Enum.map_join("/", fn part -> URI.encode(part, &URI.char_unreserved?/1) end)

      "/r/#{encoded_repo}/tree/#{encoded_rev}/#{segments}"
    end
  end

  defp raw_url(repo_name, rev_name, path) do
    encoded_repo = URI.encode(repo_name, &URI.char_unreserved?/1)
    encoded_rev = URI.encode(rev_name, &URI.char_unreserved?/1)

    if path == "" do
      "/r/#{encoded_repo}/raw/#{encoded_rev}"
    else
      segments =
        path
        |> String.split("/", trim: true)
        |> Enum.map_join("/", fn part -> URI.encode(part, &URI.char_unreserved?/1) end)

      "/r/#{encoded_repo}/raw/#{encoded_rev}/#{segments}"
    end
  end
end
