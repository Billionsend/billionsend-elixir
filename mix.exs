defmodule BillionSend.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/billionsend/billionsend-elixir"

  def project do
    [
      app: :billionsend,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [],
      description:
        "Elixir client for the BillionSend email API: every operation, idempotent sends, " <>
          "retries, inbox event streams and webhook verification.",
      package: package(),
      source_url: @source_url,
      homepage_url: "https://billionsend.com/docs",
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl, :crypto, :public_key]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => "https://billionsend.com/docs",
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
