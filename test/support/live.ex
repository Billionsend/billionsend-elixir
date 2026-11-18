defmodule BillionSend.Test.Live do
  @moduledoc """
  What the live tests (`test/e2e`) stand on: a transport that sits between the SDK
  and the real API, and the bookkeeping around it.

  The transport, for every request:

    1. checks the request the SDK built against the published OpenAPI document and
       raises before anything is sent when the contract refuses it;
    2. waits until a second has passed since the last request (the team's limit is
       shared with the company's real sending);
    3. sends it through the SDK's own default transport, counting it (150 at most);
    4. checks the answer against the document: a declared status, and a body that
       matches that status's schema. What does not match is kept as a violation.

  A 429 is waited out by the SDK (`Retry-After`); a second 429 in a row stops
  the run.

  Everything the tests create is registered with `track/3` and deleted by
  `cleanup/1`, newest first.
  """
  @behaviour BillionSend.Transport

  alias BillionSend.{Request, Response}
  alias BillionSend.Test.{Contract, Mock}

  @base_url "https://api.billionsend.com"
  @spec_url "https://billionsend.com/docs/api.openapi.json"
  @max_requests 150
  @gap_ms 1_000

  # --- the run ----------------------------------------------------------------------------

  def base_url, do: @base_url

  def start(api_key) do
    run = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          key: api_key,
          run: run,
          last: nil,
          count: 0,
          sends: 0,
          log: [],
          violations: [],
          consecutive_429: 0,
          suppressed: MapSet.new(),
          created: [],
          leftovers: []
        }
      end)

    agent
  end

  @doc "The tag every object this run creates carries: `sdk-e2e-elixir-<random>`."
  def tag(agent), do: "sdk-e2e-elixir-" <> Agent.get(agent, & &1.run)

  @doc """
  A client for the live API. `api_key:` another key than the run's. `unchecked: true`
  sends requests the contract would refuse (on purpose, to see the API refuse them
  too); the answers are still checked.
  """
  def client(agent, opts \\ []) do
    key = Keyword.get_lazy(opts, :api_key, fn -> Agent.get(agent, & &1.key) end)
    state = if Keyword.get(opts, :unchecked, false), do: {agent, :unchecked}, else: agent

    BillionSend.client(
      Keyword.merge(
        [api_key: key, base_url: @base_url, transport: {__MODULE__, state}],
        Keyword.drop(opts, [:api_key, :unchecked])
      )
    )
  end

  def requests(agent), do: Agent.get(agent, & &1.count)
  def log(agent), do: Agent.get(agent, &Enum.reverse(&1.log))
  def sends(agent), do: Agent.get(agent, & &1.sends)

  @doc "Counts an email the test is about to send; more than 20 in a run stops it."
  def count_send(agent, n \\ 1) do
    total = Agent.get_and_update(agent, fn s -> {s.sends + n, %{s | sends: s.sends + n}} end)
    if total > 20, do: raise("the live tests may send 20 emails at most; this would be #{total}")
    :ok
  end

  @doc "Downloads the published OpenAPI document (not an API request; no key is sent)."
  def fetch_spec do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(
        :get,
        {String.to_charlist(@spec_url), []},
        [
          ssl: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ],
        body_format: :binary
      )

    JSON.decode!(body)
  end

  @doc "A document without the free text (descriptions, summaries), for comparing contracts."
  def strip_text(%{} = map) do
    map
    |> Map.drop(["description", "summary"])
    |> Map.new(fn {k, v} -> {k, strip_text(v)} end)
  end

  def strip_text(list) when is_list(list), do: Enum.map(list, &strip_text/1)
  def strip_text(other), do: other

  # --- the two safety rules on mail ---------------------------------------------------------

  @simulator ~r/\Asuccess(\+[a-z0-9._-]+)?@simulator\.amazonses\.com\z/

  @doc """
  Checks a request against the two rules on mail, before anything is sent:

    1. a recipient (`to`, `cc`, `bcc`, in a body or in each body of a batch) is
       `success@simulator.amazonses.com` or a plus-alias of it, nothing else;
    2. an address the run has put on the suppression list (a suppression created
       or added in a batch) is never a recipient: mail to it would make the
       platform announce `email.suppressed` to the account's real webhook.

  Returns `{:ok, suppressed}` with the addresses suppressed so far (this request's
  included), or `{:error, reason}`.
  """
  def guard(suppressed, %Request{body: nil}), do: {:ok, suppressed}

  def guard(suppressed, %Request{} = req) do
    case json_body(req) do
      nil ->
        {:ok, suppressed}

      body ->
        suppressed = MapSet.union(suppressed, suppressions_in(req, body))
        bodies = if is_list(body), do: body, else: [body]
        recipients = for %{} = b <- bodies, key <- ~w(to cc bcc), r <- addresses(b[key]), do: r

        cond do
          bad = Enum.find(recipients, &(not Regex.match?(@simulator, &1))) ->
            {:error,
             "a recipient that is not success@simulator.amazonses.com or a plus-alias of it: #{bad}"}

          bad = Enum.find(recipients, &MapSet.member?(suppressed, &1)) ->
            {:error, "a recipient that is on the suppression list the run made: #{bad}"}

          true ->
            {:ok, suppressed}
        end
    end
  end

  defp json_body(%Request{headers: headers, body: body}) do
    type =
      Enum.find_value(headers, "", fn {k, v} -> if String.downcase(k) == "content-type", do: v end)

    if String.starts_with?(type, "application/json"), do: JSON.decode!(body)
  end

  defp suppressions_in(%Request{method: "POST", url: url}, body) do
    case URI.parse(url).path do
      "/suppressions" -> MapSet.new(addresses(body["email"]))
      "/suppressions/batch/add" -> MapSet.new(addresses(body["emails"]))
      _ -> MapSet.new()
    end
  end

  defp suppressions_in(_, _), do: MapSet.new()

  # "Name <a@b>", "a@b" or a list of them, as lower-case bare addresses.
  defp addresses(nil), do: []
  defp addresses(list) when is_list(list), do: Enum.flat_map(list, &addresses/1)

  defp addresses(text) when is_binary(text) do
    bare =
      case Regex.run(~r/<([^>]*)>/, text, capture: :all_but_first) do
        [inner] -> inner
        nil -> text
      end

    [bare |> String.trim() |> String.downcase()]
  end

  defp addresses(_), do: []

  # --- violations ---------------------------------------------------------------------------

  def violations(agent), do: Agent.get(agent, &Enum.reverse(&1.violations))

  @doc "Raises with what did not match the contract since the last call, and forgets it."
  def assert_contract(agent) do
    case Agent.get_and_update(agent, fn s -> {Enum.reverse(s.violations), %{s | violations: []}} end) do
      [] ->
        :ok

      problems ->
        raise ExUnit.AssertionError,
          message:
            "answers that do not match the published contract:\n  " <> Enum.join(problems, "\n  ")
    end
  end

  defp violation(agent, text), do: Agent.update(agent, &%{&1 | violations: [text | &1.violations]})

  # --- cleanup ------------------------------------------------------------------------------

  @doc "Registers how to delete something that was created; `label` names it in reports."
  def track(agent, label, deleter) when is_function(deleter, 0) do
    Agent.update(agent, &%{&1 | created: [{label, deleter} | &1.created]})
  end

  @doc "Takes `label` off the list: the test deleted it itself."
  def forget(agent, label) do
    Agent.update(agent, fn s ->
      %{s | created: Enum.reject(s.created, fn {l, _} -> l == label end)}
    end)
  end

  @doc "Deletes everything registered, newest first. What cannot be deleted is kept in `leftovers/1`."
  def cleanup(agent) do
    created = Agent.get_and_update(agent, fn s -> {s.created, %{s | created: []}} end)

    for {label, deleter} <- created do
      case safe(deleter) do
        :ok ->
          :ok

        {:error, %BillionSend.NotFoundError{}} ->
          :ok

        other ->
          Agent.update(
            agent,
            &%{&1 | leftovers: [{label, inspect(other, limit: 5)} | &1.leftovers]}
          )
      end
    end

    :ok
  end

  def leftovers(agent), do: Agent.get(agent, &Enum.reverse(&1.leftovers))

  defp safe(fun) do
    case fun.() do
      {:ok, _} -> :ok
      other -> other
    end
  rescue
    error -> {:raised, Exception.message(error)}
  end

  # --- the transport ------------------------------------------------------------------------

  @impl true
  def request({agent, :unchecked}, %Request{} = req), do: request(agent, req, false)
  def request(agent, %Request{} = req), do: request(agent, req, true)

  defp request(agent, %Request{} = req, check?) do
    guard!(agent, req)

    # A request the contract refuses is never sent. (The key it carries is the client's
    # own: a test may use another one, a made-up or a restricted key.)
    key =
      Enum.find_value(req.headers, fn {k, v} ->
        if String.downcase(k) == "authorization", do: String.replace_prefix(v, "Bearer ", "")
      end)

    {op, _call} = Mock.inspect_request(req, key, check?)
    throttle(agent)

    result = BillionSend.Transport.Httpc.request(nil, req)

    case result do
      {:ok, %Response{status: status} = response} ->
        record(agent, op, status)
        check_answer(agent, op, response)
        track_429(agent, status)

      {:error, error} ->
        record(agent, op, "no answer: #{inspect(error.__struct__)}")
    end

    result
  end

  @impl true
  def open_stream(_agent, _req), do: raise("the live tests open no event streams")
  @impl true
  def next_chunk(_agent, _handle), do: raise("the live tests open no event streams")
  @impl true
  def close_stream(_agent, _handle), do: :ok

  # At least a second after the previous request started, and 150 requests at most.
  defp guard!(agent, req) do
    case guard(Agent.get(agent, & &1.suppressed), req) do
      {:ok, suppressed} -> Agent.update(agent, &%{&1 | suppressed: suppressed})
      {:error, reason} -> raise "refused before sending: #{reason}"
    end
  end

  defp throttle(agent) do
    decision =
      Agent.get_and_update(agent, fn s ->
        now = System.monotonic_time(:millisecond)
        # (monotonic time may be negative: nothing has been sent yet when `last` is nil)
        wait = if s.last, do: max(s.last + @gap_ms - now, 0), else: 0

        if s.count >= @max_requests,
          do: {{:over, s.count}, s},
          else: {{:wait, wait}, %{s | last: now + wait, count: s.count + 1}}
      end)

    case decision do
      {:over, n} ->
        raise "the live tests may make #{@max_requests} requests at most; request #{n + 1} was refused"

      {:wait, wait} ->
        if wait > 0, do: Process.sleep(wait)
    end
  end

  defp record(agent, op, status) do
    Agent.update(agent, &%{&1 | log: [{op.method, op.path, status} | &1.log]})
  end

  defp track_429(agent, 429) do
    n =
      Agent.get_and_update(agent, fn s ->
        {s.consecutive_429 + 1, %{s | consecutive_429: s.consecutive_429 + 1}}
      end)

    if n >= 2, do: raise("two 429 answers in a row: stopping, as the live-test rules say")
  end

  defp track_429(agent, _), do: Agent.update(agent, &%{&1 | consecutive_429: 0})

  defp check_answer(agent, op, %Response{status: status, body: body}) do
    where = "#{op.method} #{op.path} -> #{status}"

    case Map.get(op.spec["responses"], to_string(status)) do
      nil ->
        violation(agent, "#{where}: the document declares no such status")

      declared ->
        schema = get_in(declared, ["content", "application/json", "schema"])

        cond do
          schema == nil ->
            :ok

          body in [nil, ""] ->
            violation(agent, "#{where}: an empty answer where the document describes a body")

          true ->
            case JSON.decode(body) do
              {:ok, json} ->
                problems = Contract.errors(json, schema)

                if problems != [],
                  do: violation(agent, "#{where}: #{Enum.join(Enum.take(problems, 6), "; ")}")

              {:error, _} ->
                violation(agent, "#{where}: the body is not JSON")
            end
        end
    end
  end
end
