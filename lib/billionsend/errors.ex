defmodule BillionSend.Errors do
  @moduledoc """
  The errors the SDK returns (in `{:error, error}`) and raises (from the `!` functions).

  Every error is an exception struct with the API's error shape: `status_code`,
  `name` and `message`, plus `request_id`, the API's id of the request (its
  `x-request-id` header). A failure that never produced an API answer (a
  network error, a timeout, an answer that is not JSON) takes the same shape,
  with `name` `"application_error"`.

  | Status | Exception |
  | --- | --- |
  | 400, 422 | `BillionSend.ValidationError` |
  | 401 | `BillionSend.AuthenticationError` |
  | 403 | `BillionSend.PermissionDeniedError` |
  | 404 | `BillionSend.NotFoundError` |
  | 409 | `BillionSend.ConflictError` |
  | 429 | `BillionSend.RateLimitError` (`retry_after` in seconds) |
  | 5xx | `BillionSend.APIError` |
  | other | `BillionSend.Error` |
  | no answer | `BillionSend.APIConnectionError`, `BillionSend.APITimeoutError` for timeouts |

  `BillionSend.WebhookVerificationError` is raised by `BillionSend.verify_webhook/4`.
  """

  @fields [
    message: nil,
    name: "application_error",
    status_code: nil,
    request_id: nil,
    retry_after: nil,
    response: nil
  ]

  @doc false
  def fields, do: @fields

  @type t ::
          BillionSend.Error.t()
          | BillionSend.APIConnectionError.t()
          | BillionSend.APITimeoutError.t()
          | BillionSend.ValidationError.t()
          | BillionSend.AuthenticationError.t()
          | BillionSend.PermissionDeniedError.t()
          | BillionSend.NotFoundError.t()
          | BillionSend.ConflictError.t()
          | BillionSend.RateLimitError.t()
          | BillionSend.APIError.t()
          | BillionSend.WebhookVerificationError.t()

  @modules [
    BillionSend.Error,
    BillionSend.APIConnectionError,
    BillionSend.APITimeoutError,
    BillionSend.ValidationError,
    BillionSend.AuthenticationError,
    BillionSend.PermissionDeniedError,
    BillionSend.NotFoundError,
    BillionSend.ConflictError,
    BillionSend.RateLimitError,
    BillionSend.APIError,
    BillionSend.WebhookVerificationError
  ]

  @doc "Whether `value` is one of the SDK's errors."
  def error?(%module{}) when module in @modules, do: true
  def error?(_), do: false

  @doc "The error module of an HTTP status."
  def module_for(status) when status in [400, 422], do: BillionSend.ValidationError
  def module_for(401), do: BillionSend.AuthenticationError
  def module_for(403), do: BillionSend.PermissionDeniedError
  def module_for(404), do: BillionSend.NotFoundError
  def module_for(409), do: BillionSend.ConflictError
  def module_for(429), do: BillionSend.RateLimitError
  def module_for(status) when status >= 500, do: BillionSend.APIError
  def module_for(_), do: BillionSend.Error

  @doc false
  defmacro __using__(_) do
    quote do
      defexception BillionSend.Errors.fields()

      @type t :: %__MODULE__{
              message: String.t(),
              name: String.t(),
              status_code: non_neg_integer() | nil,
              request_id: String.t() | nil,
              retry_after: float() | nil,
              response: BillionSend.Response.t() | nil
            }

      @impl true
      def message(%{message: message, name: name, status_code: status}) do
        prefix = if status, do: "#{status} ", else: ""
        "#{prefix}#{name}: #{message}"
      end
    end
  end
end

defmodule BillionSend.Error do
  @moduledoc "An error answer with a status no other error covers; see `BillionSend.Errors`."
  use BillionSend.Errors
end

defmodule BillionSend.APIConnectionError do
  @moduledoc "The request never got an answer: DNS, connection, TLS or protocol failure."
  use BillionSend.Errors
end

defmodule BillionSend.APITimeoutError do
  @moduledoc "The request timed out (retried like `BillionSend.APIConnectionError`)."
  use BillionSend.Errors
end

defmodule BillionSend.ValidationError do
  @moduledoc "400 or 422: the request was refused as invalid."
  use BillionSend.Errors
end

defmodule BillionSend.AuthenticationError do
  @moduledoc "401: the API key is missing, malformed or revoked."
  use BillionSend.Errors
end

defmodule BillionSend.PermissionDeniedError do
  @moduledoc "403: the key may not do this."
  use BillionSend.Errors
end

defmodule BillionSend.NotFoundError do
  @moduledoc "404: no such resource."
  use BillionSend.Errors
end

defmodule BillionSend.ConflictError do
  @moduledoc "409: the request conflicts with the current state (or an idempotency key)."
  use BillionSend.Errors
end

defmodule BillionSend.RateLimitError do
  @moduledoc "429: too many requests; `retry_after` holds the server's hint in seconds."
  use BillionSend.Errors
end

defmodule BillionSend.APIError do
  @moduledoc "5xx: the API failed to answer the request."
  use BillionSend.Errors
end

defmodule BillionSend.WebhookVerificationError do
  @moduledoc "A webhook delivery whose signature, timestamp or headers do not check out."
  use BillionSend.Errors
end
