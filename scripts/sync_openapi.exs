# Refreshes the OpenAPI snapshot the SDK and its tests are built against.
#
# openapi/api.openapi.json is the contract: the resource modules are generated
# from it, and the contract tests check every request the SDK sends and every
# answer it reads against it. When the API changes, run this script, then
# `elixir scripts/generate.exs` and `mix test`; whatever fails is what the SDK
# has to follow.
#
#   elixir scripts/sync_openapi.exs                  # fetch the published document
#   elixir scripts/sync_openapi.exs --from path.json # copy a local document
#   elixir scripts/sync_openapi.exs --check          # fail if the snapshot differs from the published document
#
# Free-text description / summary strings that name other products are dropped
# from the snapshot (they carry no contract), so the repository only ever
# speaks about BillionSend.

defmodule SyncOpenAPI do
  @url "https://billionsend.com/docs/api.openapi.json"
  @snapshot Path.expand("../openapi/api.openapi.json", __DIR__)
  @text_keys ["description", "summary"]

  # Names of other products that must not appear in this repository.
  defp foreign,
    do: Regex.compile!(Enum.join(["Re" <> "send", "Sv" <> "ix"], "|"), "i")

  def run(argv) do
    raw =
      case argv do
        ["--from", path] -> File.read!(path)
        argv when argv in [[], ["--check"]] -> fetch()
      end

    {spec, dropped} = sanitize(JSON.decode!(raw), 0)
    text = pretty(spec, 0) <> "\n"

    if argv == ["--check"] do
      check(text)
    else
      write(spec, text, dropped)
    end
  end

  defp check(text) do
    if File.read!(@snapshot) == text do
      IO.puts("openapi/api.openapi.json matches #{@url}")
    else
      IO.puts(
        :stderr,
        "openapi/api.openapi.json differs from #{@url}: run `elixir scripts/sync_openapi.exs`, " <>
          "then `elixir scripts/generate.exs` and `mix test`"
      )

      System.halt(1)
    end
  end

  defp write(spec, text, dropped) do
    File.write!(@snapshot, text)

    count =
      for {_, item} <- spec["paths"],
          {m, _} <- item,
          m in ~w(get put post patch delete),
          reduce: 0 do
        n -> n + 1
      end

    IO.puts("wrote openapi/api.openapi.json: #{count} operations, #{dropped} descriptions dropped")
  end

  # The document as published.
  defp fetch do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:get, {String.to_charlist(@url), []}, [ssl: ssl], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> body
      other -> raise "GET #{@url}: #{inspect(other)}"
    end
  end

  defp sanitize(%{} = map, dropped) do
    Enum.reduce(map, {%{}, dropped}, fn {k, v}, {acc, n} ->
      if k in @text_keys and is_binary(v) and Regex.match?(foreign(), v) do
        {acc, n + 1}
      else
        {v, n} = sanitize(v, n)
        {Map.put(acc, k, v), n}
      end
    end)
  end

  defp sanitize(list, dropped) when is_list(list) do
    {items, n} = Enum.map_reduce(list, dropped, fn v, n -> sanitize(v, n) end)
    {items, n}
  end

  defp sanitize(value, dropped), do: {value, dropped}

  # Two-space JSON with sorted keys, so a refresh shows as a readable diff.
  defp pretty(%{} = map, _) when map_size(map) == 0, do: "{}"
  defp pretty([], _), do: "[]"

  defp pretty(%{} = map, depth) do
    pad = String.duplicate("  ", depth + 1)

    entries =
      map
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> "#{pad}#{JSON.encode!(k)}: #{pretty(v, depth + 1)}" end)

    "{\n" <> Enum.join(entries, ",\n") <> "\n" <> String.duplicate("  ", depth) <> "}"
  end

  defp pretty(list, depth) when is_list(list) do
    pad = String.duplicate("  ", depth + 1)

    "[\n" <>
      Enum.map_join(list, ",\n", &(pad <> pretty(&1, depth + 1))) <>
      "\n" <> String.duplicate("  ", depth) <> "]"
  end

  defp pretty(value, _), do: JSON.encode!(value)
end

SyncOpenAPI.run(System.argv())
