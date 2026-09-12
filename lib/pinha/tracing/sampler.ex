defmodule Pinha.Tracing.Sampler do
  @moduledoc """
  Drops traces for static file requests, which are a dozen 304s per page load.

  Used as the root sampler of a parent-based one, so spans inside a request
  follow the decision made for the request.
  """

  @behaviour :otel_sampler

  @dropped_prefixes ["/assets/"]
  @dropped_paths ["/robots.txt", "/favicon.ico"]

  @impl true
  def setup(opts), do: opts

  @impl true
  def description(_config), do: <<"PinhaSampler">>

  @impl true
  def should_sample(ctx, _trace_id, _links, _name, _kind, attributes, _config) do
    tracestate = ctx |> :otel_tracer.current_span_ctx() |> :otel_span.tracestate()

    if static?(attributes) do
      {:drop, [], tracestate}
    else
      {:record_and_sample, [], tracestate}
    end
  end

  defp static?(attributes) do
    case Map.get(attributes, :"url.path") do
      path when is_binary(path) ->
        path in @dropped_paths or Enum.any?(@dropped_prefixes, &String.starts_with?(path, &1))

      _ ->
        false
    end
  end
end
