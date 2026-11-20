defmodule BillionSend.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/billionsend/billionsend-elixir"

  def project do
    [
      app: :billionsend,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [],
      test_coverage: test_coverage(),
      aliases: aliases(),
      description:
        "Elixir client for the BillionSend email API: every operation, idempotent sends, " <>
          "retries, inbox event streams and webhook verification.",
      package: package(),
      source_url: @source_url,
      homepage_url: "https://billionsend.com/docs",
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]]
    ]
  end

  def cli, do: [preferred_envs: [e2e: :test]]

  # `BILLIONSEND_E2E_API_KEY=bs_... mix e2e`: the live tests (test/e2e), in order, against the real API.
  defp aliases do
    [e2e: ["test --only e2e --seed 0 test/e2e"]]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl, :crypto, :public_key]]
  end

  # `mix test --cover` fails below 95% of the lines. Two scopes, one run each:
  # the hand-written runtime (default) and the code generated from the OpenAPI
  # snapshot (`COVERAGE_SCOPE=generated`). Test support code is in neither.
  # `scripts/branch_coverage.exs` adds the branches of the hand-written scope.
  defp test_coverage, do: if(Mix.env() == :test, do: coverage_gates(), else: [])

  defp coverage_gates do
    groups =
      "lib/billionsend/resources.ex"
      |> File.read!()
      |> then(&Regex.scan(~r/^defmodule BillionSend\.(\w+)/m, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.join("|")

    generated = Regex.compile!("\\ABillionSend\\.(#{groups})(\\.|\\z)")
    support = ~r/\ABillionSend\.Test\./

    ignore =
      case System.get_env("COVERAGE_SCOPE", "handwritten") do
        "generated" -> [Regex.compile!("\\A(?!BillionSend\\.(#{groups})(\\.|\\z))")]
        "handwritten" -> [generated, support]
      end

    [summary: [threshold: 95], ignore_modules: ignore]
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
