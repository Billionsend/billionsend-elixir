defmodule BillionSend.ErrorsTest do
  use ExUnit.Case, async: true

  import BillionSend.Test.Helpers
  alias BillionSend.Test.Mock

  for {status, module} <- [
        {400, BillionSend.ValidationError},
        {401, BillionSend.AuthenticationError},
        {403, BillionSend.PermissionDeniedError},
        {404, BillionSend.NotFoundError},
        {409, BillionSend.ConflictError},
        {422, BillionSend.ValidationError},
        {429, BillionSend.RateLimitError},
        {500, BillionSend.APIError},
        {503, BillionSend.APIError},
        {418, BillionSend.Error}
      ] do
    test "status #{status} is #{inspect(module)}" do
      {client, mock} = client(max_retries: 0)

      Mock.error(
        mock,
        "GET",
        "/domains/{id}",
        unquote(status),
        "some_error",
        "Something went wrong",
        headers: [{"x-request-id", "req_123"}]
      )

      assert {:error, error} = BillionSend.Domains.get(client, id())
      assert %unquote(module){} = error
      assert error.status_code == unquote(status)
      assert error.name == "some_error"
      assert error.message == "Something went wrong"
      assert error.request_id == "req_123"
      assert Exception.message(error) == "#{unquote(status)} some_error: Something went wrong"
      assert BillionSend.Errors.error?(error)
    end
  end

  test "a rate limit carries retry_after" do
    {client, mock} = client(max_retries: 0)

    Mock.error(mock, "GET", "/domains", 429, "rate_limit_exceeded", "Slow down",
      headers: [{"retry-after", "7"}]
    )

    assert {:error, %BillionSend.RateLimitError{retry_after: 7.0}} =
             BillionSend.Domains.list(client)
  end

  test "an error without a JSON body keeps its text" do
    {client, mock} = client(max_retries: 0)

    Mock.respond(mock, "GET", "/domains", 502,
      body: "Bad gateway",
      headers: [{"content-type", "text/plain"}]
    )

    assert {:error, %BillionSend.APIError{name: "application_error", message: "Bad gateway"}} =
             BillionSend.Domains.list(client)
  end

  test "a failure without an answer" do
    {client, mock} = client(max_retries: 0)
    Mock.fail(mock, "GET", "/domains", %BillionSend.APITimeoutError{message: "Request timed out"})

    assert {:error,
            %BillionSend.APITimeoutError{
              status_code: nil,
              name: "application_error",
              request_id: nil
            }} =
             BillionSend.Domains.list(client)
  end
end
