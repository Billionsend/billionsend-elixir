defmodule BillionSend do
  @moduledoc """
  The BillionSend API: sending, receiving, contacts, broadcasts and agent inboxes.

      client = BillionSend.client()  # reads BILLIONSEND_API_KEY

      {:ok, email} =
        BillionSend.Emails.send(client, %{
          from: "Acme <hello@acme.dev>",
          to: ["ada@example.com"],
          subject: "Welcome to Acme",
          html: "<p>Thanks for signing up!</p>"
        })

  Operations are functions of resource modules named after each operation's
  `operationId` (`emails.receiving.attachments.list` is
  `BillionSend.Emails.Receiving.Attachments.list/3`). Each returns `{:ok, answer}`
  or `{:error, error}`; the same name with `!` returns the answer or raises.
  """

  @version Mix.Project.config()[:version]

  @doc "The SDK's version."
  def version, do: @version

  @doc "Builds a client; see `BillionSend.Client.new/1` for the options."
  defdelegate client(opts \\ []), to: BillionSend.Client, as: :new

  @doc "Checks a webhook delivery; see `BillionSend.Webhook.verify/4`."
  defdelegate verify_webhook(payload, headers, secret, opts \\ []),
    to: BillionSend.Webhook,
    as: :verify

  @doc "Like `verify_webhook/4`, but returns the event or raises."
  defdelegate verify_webhook!(payload, headers, secret, opts \\ []),
    to: BillionSend.Webhook,
    as: :verify!
end
