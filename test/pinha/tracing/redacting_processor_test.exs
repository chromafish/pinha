defmodule Pinha.Tracing.RedactingProcessorTest do
  @moduledoc "What leaves for the exporter, and what does not."

  use ExUnit.Case, async: true

  require Record

  alias Pinha.Tracing.RedactingProcessor

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  test "drops the query of an integration route, keeping everything else" do
    redacted =
      "/integrations/github/callback"
      |> span_with_query()
      |> RedactingProcessor.redact()
      |> attributes()

    refute Map.has_key?(redacted, :"url.query")
    refute Map.has_key?(redacted, :"url.full")
    assert redacted[:"url.path"] == "/integrations/github/callback"
    assert redacted[:"http.response.status_code"] == 302
  end

  test "leaves every other route alone" do
    kept = "/r/demo" |> span_with_query() |> RedactingProcessor.redact() |> attributes()

    assert kept[:"url.query"] == "code=secret&state=abc"
  end

  defp span_with_query(path) do
    attributes =
      :otel_attributes.new(
        %{
          :"url.path" => path,
          :"url.query" => "code=secret&state=abc",
          :"url.full" => "https://pinha.test#{path}?code=secret",
          :"http.response.status_code" => 302
        },
        128,
        :infinity
      )

    span(name: "GET", attributes: attributes)
  end

  defp attributes(span), do: span |> span(:attributes) |> :otel_attributes.map()
end
