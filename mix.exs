defmodule Pinha.MixProject do
  use Mix.Project

  def project do
    [
      app: :pinha,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: releases()
    ]
  end

  # One self-contained tarball: the BEAM, every application including `ssh`,
  # and the runtime configuration read at boot. It is built for the OS and
  # architecture it was built on, so it deploys to that pair and no other.
  defp releases do
    [
      pinha: [
        include_executables_for: [:unix],
        steps: [&build_assets/1, :assemble, :tar],
        # The exporter has to be up before anything it exports for, and a
        # telemetry pipeline that dies is not a reason to take the node down.
        applications: [opentelemetry_exporter: :permanent, opentelemetry: :temporary]
      ]
    ]
  end

  # The browser bundle is built from `assets/` before the release is assembled,
  # so a tarball always carries the JavaScript matching the code inside it.
  defp build_assets(release) do
    Mix.Task.run("assets.deploy")
    release
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Pinha.Application, []},
      extra_applications: [:logger, :runtime_tools, :ssh]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      # Drives a headless browser over the DevTools protocol, which is the only
      # way to get a real passkey assertion into the suite.
      {:mint_web_socket, "~> 1.0", only: :test},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:wax_, "~> 0.7.0"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.2"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:earmark, "~> 1.4"},
      {:html_sanitize_ex, "~> 1.4"},
      # Background work in Postgres: mirror syncs and provider events.
      {:oban, "~> 2.24"},
      # Provider APIs, stubbed with `Req.Test` in the suite.
      {:req, "~> 0.7.4"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["esbuild pinha"],
      "assets.deploy": ["esbuild pinha --minify"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "assets.setup",
        "assets.build",
        "format",
        "test"
      ]
    ]
  end
end
