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

  describe "an answer that is not the API's error shape" do
    defp refuse(body, status \\ 500, headers \\ []) do
      {client, mock} = client(max_retries: 0)
      Mock.respond(mock, "GET", "/domains", status, body: body, headers: headers)
      assert {:error, error} = BillionSend.Domains.list(client)
      error
    end

    test "a JSON error without name or message gets the defaults" do
      error = refuse(~s({"statusCode":404}), 404)
      assert %BillionSend.NotFoundError{name: "application_error", message: "HTTP 404"} = error
    end

    test "a name or message that is not text is ignored" do
      error = refuse(~s({"name":1,"message":{"a":1}}), 400)
      assert %BillionSend.ValidationError{name: "application_error", message: "HTTP 400"} = error
    end

    test "a JSON body that is not an object is shown as text" do
      assert %BillionSend.APIError{message: "[1,2]"} = refuse("[1,2]")
    end

    test "an empty body is only its status" do
      assert %BillionSend.APIError{message: "HTTP 502", name: "application_error"} = refuse("", 502)
      assert %BillionSend.APIError{message: "HTTP 502"} = refuse("  \n", 502)
    end

    test "a page of HTML is shortened to 500 characters and keeps its whole body" do
      html = "<html>" <> String.duplicate("x", 2_000) <> "</html>"
      error = refuse(html, 502, [{"content-type", "text/html"}])
      assert String.length(error.message) == 500
      assert error.response.body == html
      assert error.response.status == 502
      assert BillionSend.Response.header(error.response, "Content-Type") == "text/html"
    end

    test "the request id is nil when the answer has none" do
      assert refuse(~s({"statusCode":500,"name":"x","message":"y"})).request_id == nil
    end
  end

  test "every status has its error, and only the SDK's errors are errors" do
    for {status, module} <- [
          {400, BillionSend.ValidationError},
          {422, BillionSend.ValidationError},
          {401, BillionSend.AuthenticationError},
          {403, BillionSend.PermissionDeniedError},
          {404, BillionSend.NotFoundError},
          {409, BillionSend.ConflictError},
          {429, BillionSend.RateLimitError},
          {500, BillionSend.APIError},
          {599, BillionSend.APIError},
          {301, BillionSend.Error},
          {410, BillionSend.Error}
        ] do
      assert BillionSend.Errors.module_for(status) == module
    end

    for module <- [
          BillionSend.Error,
          BillionSend.APIConnectionError,
          BillionSend.APITimeoutError,
          BillionSend.WebhookVerificationError
        ] do
      assert BillionSend.Errors.error?(struct(module, message: "x"))
    end

    refute BillionSend.Errors.error?(%RuntimeError{message: "x"})
    refute BillionSend.Errors.error?(:error)
  end

  test "an error that has no status reads without one" do
    error = %BillionSend.APITimeoutError{message: "Request timed out"}
    assert Exception.message(error) == "application_error: Request timed out"
  end
end
