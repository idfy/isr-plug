defmodule ISRPlug.MixProject do
  use Mix.Project

  def project do
    [
      app: :isr_plug,
      version: "0.1.1",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A generic Plug for implementing Incremental Static Regeneration (ISR).",
      package: package(),
      # Docs
      name: "ISRPlug",
      source_url: "https://github.com/idfy/isr-plug",
      docs: [
        main: "ISRPlug",
        extras: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
      # No application startup needed for the plug itself
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.17"},
      {:ex_doc, "~> 0.37", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Ziyak Jehangir"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/idfy/isr-plug"}
    ]
  end
end
