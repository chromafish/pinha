defmodule Pinha.Tracing.RedactingProcessor do
  @moduledoc """
  A span processor that removes the query string of integration routes
  before spans are handed to the processor that exports them.

  An authorization callback carries its `code` and `state` in the query
  string, which the HTTP instrumentation records as `url.query`. Dropping it
  here means no credential reaches an exporter, whatever the instrumentation
  decides to collect.

  It wraps another processor, named in its `:next` configuration, and starts
  it as its own child, so the batch processor keeps doing the exporting.
  """

  @behaviour :otel_span_processor

  require Record

  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  # `otel_attributes` keeps its record in a module rather than a header, so
  # its shape is spelled out here.
  Record.defrecordp(:attributes, [:count_limit, :value_length_limit, :dropped, :map])

  @redacted_prefixes ["/integrations/"]
  @redacted_keys [:"url.query", :"url.full", :"http.target"]

  @doc "Starts the wrapped processor and keeps it in this one's configuration."
  @spec start_link(map()) :: {:ok, pid(), map()} | {:error, term()}
  def start_link(%{next: {module, config}} = own) do
    case :otel_span_processor.start_link(module, config) do
      {:ok, pid, config} -> {:ok, pid, %{own | next: {module, config}}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def on_start(ctx, span, %{next: {module, config}}),
    do: module.on_start(ctx, redact(span), config)

  @impl true
  def on_end(span, %{next: {module, config}}), do: module.on_end(redact(span), config)

  @impl true
  def force_flush(%{next: {module, config}}), do: module.force_flush(config)

  @doc """
  The span with the query string removed, when it belongs to a route whose
  query carries credentials.
  """
  def redact(span) do
    attrs = span(span, :attributes)

    if redact?(attrs) do
      span(span, attributes: without_query(attrs))
    else
      span
    end
  end

  defp redact?(attrs) do
    map = attribute_map(attrs)

    Enum.any?(@redacted_keys, &Map.has_key?(map, &1)) and
      case Map.get(map, :"url.path") do
        path when is_binary(path) -> Enum.any?(@redacted_prefixes, &String.starts_with?(path, &1))
        _ -> false
      end
  end

  defp without_query(attrs) do
    map = attrs |> attribute_map() |> Map.drop(@redacted_keys)

    :otel_attributes.new(
      map,
      attributes(attrs, :count_limit),
      attributes(attrs, :value_length_limit)
    )
  end

  defp attribute_map(attrs) when Record.is_record(attrs, :attributes), do: attributes(attrs, :map)
  defp attribute_map(_attrs), do: %{}
end
