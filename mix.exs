defmodule Tractor.MixProject do
  use Mix.Project

  def project do
    [
      app: :tractor,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      escript: [main_module: Tractor.CLI]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Tractor.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dotx, "~> 0.3"},
      {:acpex, "~> 0.1"},
      {:jason, "~> 1.4"},
      {:mox, "~> 1.2", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      format_check: ["format --check-formatted"]
    ]
  end
end
