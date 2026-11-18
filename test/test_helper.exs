# The live tests (test/e2e) run only through `mix e2e`.
ExUnit.start(exclude: [:e2e])

defmodule BillionSend.Test.Helpers do
  alias BillionSend.Test.{Contract, Mock}

  def id, do: "6a1f1d38-3c55-4a4e-9a57-0f2b3c4d5e6f"
  def id2, do: "7b2e2e49-4d66-4b5f-8b68-1a3c4d5e6f70"

  @doc "A client on a fresh contract mock; waits are sent to the test process as {:slept, ms}."
  def client(opts \\ []) do
    mock = Mock.start()
    parent = self()

    client =
      BillionSend.client(
        Keyword.merge(
          [
            api_key: Contract.api_key(),
            base_url: Contract.base_url(),
            transport: {Mock, mock},
            sleep: fn ms -> send(parent, {:slept, ms}) end
          ],
          opts
        )
      )

    {client, mock}
  end

  @doc "Milliseconds the client waited, in order."
  def sleeps(acc \\ []) do
    receive do
      {:slept, ms} -> sleeps([ms | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
