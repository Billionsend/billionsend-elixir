defmodule BillionSend.BrandLogoTest do
  @moduledoc """
  The brand and logo operations, the unsubscribe-page settings of a domain and the
  dormant-contact fields of a broadcast: the request each function sends (method,
  path, JSON body or the parsed multipart form, file name and content type) and
  the answer it reads. Every request is also checked against the OpenAPI snapshot
  by the contract mock.
  """
  use ExUnit.Case, async: false

  import BillionSend.Test.Helpers

  alias BillionSend.Test.{Contract, ContractServer, Mock}
  alias BillionSend.Test.Mock.Call

  # A real 1x1 PNG: the signature has a byte above 127 and the data a NUL and a CRLF pair.
  @png Base.decode16!(
         "89504E470D0A1A0A0000000D4948445200000001000000010806000000" <>
           "1F15C4890000000D4944415478DA63FCFFFF3F0300060003FF0E0AD7F10000000049454E44AE426082"
       )

  defp parts(%Call{request: req}) do
    type = Call.header(%Call{request: req}, "content-type")
    assert "multipart/form-data; boundary=" <> boundary = type

    req.body
    |> String.split("--" <> boundary)
    |> Enum.drop(1)
    |> Enum.reject(&String.starts_with?(&1, "--"))
    |> Enum.map(fn part ->
      [head, value] =
        part
        |> String.trim_leading("\r\n")
        |> String.replace_suffix("\r\n", "")
        |> String.split("\r\n\r\n", parts: 2)

      [_, name] = Regex.run(~r/name="([^"]+)"/, head)
      {name, head, value}
    end)
  end

  defp assert_png_form(call, filename, content_type) do
    assert [{"file", head, @png}] = parts(call)
    assert head =~ ~s(filename="#{filename}")
    assert head =~ "Content-Type: #{content_type}"
    # Nothing but the Content-Disposition and Content-Type lines.
    assert length(String.split(head, "\r\n")) == 2
  end

  defp brand(overrides \\ %{}) do
    Map.merge(
      %{
        "object" => "brand",
        "logo_url" => nil,
        "accent_color" => "#2B44FF",
        "font" => "serif",
        "company_address" => "1 Main St, Springfield",
        "powered_by" => true,
        "powered_by_locked" => true,
        "show_topics" => false,
        "branding_locked" => false
      },
      overrides
    )
  end

  describe "Brand" do
    test "get reads the brand, nulls and read-only flags included" do
      {client, mock} = client()
      Mock.respond(mock, "GET", "/brand", 200, json: brand())

      assert {:ok, answer} = BillionSend.Brand.get(client)
      assert answer["logo_url"] == nil
      assert answer["font"] == "serif"
      assert answer["powered_by_locked"] == true
      assert answer["branding_locked"] == false

      assert [%Call{request: %{method: "GET", body: nil}, body: nil}] = Mock.calls(mock)
      assert Mock.violations(mock) == []
    end

    test "update sends the fields as JSON, a null clears and an unsent field is left out" do
      {client, mock} = client()

      Mock.respond(mock, "PATCH", "/brand", 200,
        json: brand(%{"accent_color" => nil, "powered_by" => false})
      )

      assert {:ok, answer} =
               BillionSend.Brand.update(client, %{
                 accent_color: nil,
                 font: "mono",
                 company_address: "1 Main St, Springfield",
                 powered_by: false,
                 show_topics: true
               })

      assert answer["accent_color"] == nil
      assert answer["powered_by"] == false

      [call] = Mock.calls(mock)
      assert call.request.method == "PATCH"
      assert Call.header(call, "content-type") == "application/json"

      assert call.body == %{
               "accent_color" => nil,
               "font" => "mono",
               "company_address" => "1 Main St, Springfield",
               "powered_by" => false,
               "show_topics" => true
             }

      assert Mock.violations(mock) == []
    end

    test "update answers a 422 as a ValidationError" do
      {client, mock} = client()
      Mock.error(mock, "PATCH", "/brand", 422, "validation_error", "accent_color must be #rrggbb")

      assert {:error, %BillionSend.ValidationError{status_code: 422}} =
               BillionSend.Brand.update(client, %{accent_color: "blue"})
    end

    test "a domain-scoped key is refused with 403 restricted_api_key" do
      {client, mock} = client()

      Mock.error(
        mock,
        "GET",
        "/brand",
        403,
        "restricted_api_key",
        "This key is limited to some domains"
      )

      assert {:error, %BillionSend.PermissionDeniedError{name: "restricted_api_key"}} =
               BillionSend.Brand.get(client)
    end
  end

  describe "logo uploads" do
    test "Brand.Logo.upload: PUT /brand/logo, one file part with its name and type, every byte kept" do
      {client, mock} = client()
      url = "https://assets.billionsend.com/logos/team/3f2a.png"
      Mock.respond(mock, "PUT", "/brand/logo", 200, json: %{"object" => "logo", "logo_url" => url})

      assert {:ok, %{"object" => "logo", "logo_url" => ^url}} =
               BillionSend.Brand.Logo.upload(client, %{file: {"logo.png", @png, "image/png"}})

      [call] = Mock.calls(mock)
      assert call.request.method == "PUT"
      assert call.request.url == Contract.base_url() <> "/brand/logo"
      refute Call.header(call, "content-type") =~ "json"
      assert_png_form(call, "logo.png", "image/png")
      assert Mock.violations(mock) == []
    end

    test "without a content type the part is application/octet-stream, the API judges the bytes" do
      {client, mock} = client()
      assert {:ok, _} = BillionSend.Brand.Logo.upload(client, file: {"logo.png", @png})
      assert_png_form(hd(Mock.calls(mock)), "logo.png", "application/octet-stream")
    end

    test "Domains.UnsubscribePage.Logo.upload: PUT with the domain id in the path" do
      {client, mock} = client()
      url = "https://assets.billionsend.com/logos/domain/9c1d.png"

      Mock.respond(mock, "PUT", "/domains/{id}/unsubscribe-page/logo", 200,
        json: %{"object" => "logo", "logo_url" => url}
      )

      assert {:ok, %{"logo_url" => ^url}} =
               BillionSend.Domains.UnsubscribePage.Logo.upload(client, id(), %{
                 file: {"acme.png", @png, "image/png"}
               })

      [call] = Mock.calls(mock)
      assert call.request.method == "PUT"
      assert call.path_params == %{"id" => id()}
      assert call.request.url == Contract.base_url() <> "/domains/#{id()}/unsubscribe-page/logo"
      assert_png_form(call, "acme.png", "image/png")
      assert Mock.violations(mock) == []
    end

    test "a missing storage (404) and a refused file (422) come back as errors" do
      {client, mock} = client()
      Mock.error(mock, "PUT", "/brand/logo", 404, "not_found", "Logo storage is not configured")

      assert {:error, %BillionSend.NotFoundError{}} =
               BillionSend.Brand.Logo.upload(client, %{file: {"l.png", @png}})

      Mock.error(
        mock,
        "PUT",
        "/brand/logo",
        422,
        "validation_error",
        "The file is not a PNG, JPEG or WebP image"
      )

      assert {:error, %BillionSend.ValidationError{}} =
               BillionSend.Brand.Logo.upload(client, %{file: {"l.svg", "<svg/>"}})
    end

    test "an upload is not repeated after a 5xx" do
      {client, mock} = client()
      Mock.error(mock, "PUT", "/brand/logo", 503, "unavailable", "Try later")

      assert {:error, %BillionSend.APIError{status_code: 503}} =
               BillionSend.Brand.Logo.upload(client, %{file: {"l.png", @png}})

      assert length(Mock.calls(mock)) == 1

      {client, mock} = client()

      Mock.error(
        mock,
        "PUT",
        "/domains/{id}/unsubscribe-page/logo",
        503,
        "unavailable",
        "Try later"
      )

      assert {:error, %BillionSend.APIError{}} =
               BillionSend.Domains.UnsubscribePage.Logo.upload(client, id(), %{
                 file: {"l.png", @png}
               })

      assert length(Mock.calls(mock)) == 1
    end

    test "an upload with an idempotency key is repeated after a 5xx, with the same form" do
      {client, mock} = client()
      Mock.error(mock, "PUT", "/brand/logo", 503, "unavailable", "Try later")

      assert {:ok, _} =
               BillionSend.Brand.Logo.upload(client, %{file: {"l.png", @png, "image/png"}},
                 extra_headers: [{"Idempotency-Key", "logo-1"}]
               )

      assert [first, second] = Mock.calls(mock)
      assert first.request.body == second.request.body
      assert Call.header(second, "idempotency-key") == "logo-1"
      assert_png_form(second, "l.png", "image/png")
    end

    test "a 429 is retried after its Retry-After, with the same form" do
      {client, mock} = client()

      Mock.error(mock, "PUT", "/brand/logo", 429, "rate_limit_exceeded", "Slow down",
        headers: [{"retry-after", "2"}]
      )

      assert {:ok, _} = BillionSend.Brand.Logo.upload(client, %{file: {"l.png", @png, "image/png"}})
      assert sleeps() == [2000]
      assert [first, second] = Mock.calls(mock)
      assert first.request.body == second.request.body
      assert_png_form(second, "l.png", "image/png")
    end

    test "over a real socket: the default transport sends a PUT form whose bytes arrive whole" do
      mock = Mock.start()
      server = ContractServer.start(mock)

      try do
        client = BillionSend.client(api_key: Contract.api_key(), base_url: server.base_url)
        url = "https://assets.billionsend.com/logos/team/77ab.png"

        Mock.respond(mock, "PUT", "/brand/logo", 200,
          json: %{"object" => "logo", "logo_url" => url}
        )

        Mock.respond(mock, "PUT", "/domains/{id}/unsubscribe-page/logo", 200,
          json: %{"object" => "logo", "logo_url" => url}
        )

        assert {:ok, %{"logo_url" => ^url}} =
                 BillionSend.Brand.Logo.upload(client, %{file: {"logo.png", @png, "image/png"}})

        assert {:ok, %{"logo_url" => ^url}} =
                 BillionSend.Domains.UnsubscribePage.Logo.upload(client, id(), %{
                   file: {"d.png", @png, "image/png"}
                 })

        [brand_call, domain_call] = Mock.calls(mock)
        assert_png_form(brand_call, "logo.png", "image/png")
        assert_png_form(domain_call, "d.png", "image/png")
        assert Call.header(brand_call, "content-length") == "#{byte_size(brand_call.request.body)}"
        assert Mock.violations(mock) == []
      after
        ContractServer.stop(server)
      end
    end

    test "delete answers the removal; DELETE is repeated after a 5xx" do
      {client, mock} = client()

      Mock.respond(mock, "DELETE", "/brand/logo", 200,
        json: %{"object" => "logo", "deleted" => true}
      )

      assert {:ok, %{"object" => "logo", "deleted" => true}} = BillionSend.Brand.Logo.delete(client)

      Mock.error(
        mock,
        "DELETE",
        "/domains/{id}/unsubscribe-page/logo",
        503,
        "unavailable",
        "Try later"
      )

      Mock.respond(mock, "DELETE", "/domains/{id}/unsubscribe-page/logo", 200,
        json: %{"object" => "logo", "deleted" => true}
      )

      assert {:ok, %{"deleted" => true}} =
               BillionSend.Domains.UnsubscribePage.Logo.delete(client, id())

      assert [brand, d1, d2] = Mock.calls(mock)
      assert {brand.request.method, brand.request.body} == {"DELETE", nil}
      assert d1.path_params == %{"id" => id()}
      assert d2.request.url == Contract.base_url() <> "/domains/#{id()}/unsubscribe-page/logo"
      assert Mock.violations(mock) == []
    end

    test "an empty domain id raises before sending" do
      {client, mock} = client()

      assert_raise ArgumentError, fn ->
        BillionSend.Domains.UnsubscribePage.Logo.upload(client, "", %{file: {"l.png", @png}})
      end

      assert_raise ArgumentError, fn ->
        BillionSend.Domains.UnsubscribePage.Logo.delete(client, nil)
      end

      assert Mock.calls(mock) == []
    end
  end

  describe "a domain's unsubscribe page" do
    @page %{
      "logo_url" => nil,
      "accent_color" => "#2B44FF",
      "font" => "system",
      "company_address" => nil,
      "show_topics" => true,
      "support_url" => "https://acme.dev/help",
      "powered_by" => nil,
      "powered_by_effective" => true
    }

    test "update sends support_url and powered_by, null clears them" do
      {client, mock} = client()

      assert {:ok, _} =
               BillionSend.Domains.update(client, id(), %{
                 unsubscribe_page: %{support_url: "https://acme.dev/help", powered_by: false}
               })

      assert {:ok, _} =
               BillionSend.Domains.update(client, id(), %{
                 unsubscribe_page: %{support_url: nil, powered_by: nil}
               })

      assert [one, two] = Mock.calls(mock)

      assert one.body == %{
               "unsubscribe_page" => %{
                 "support_url" => "https://acme.dev/help",
                 "powered_by" => false
               }
             }

      assert two.body == %{"unsubscribe_page" => %{"support_url" => nil, "powered_by" => nil}}
      assert Mock.violations(mock) == []
    end

    test "get reads the new fields: a null logo_url, powered_by null and powered_by_effective" do
      {client, mock} = client()
      op = Contract.operation("GET", "/domains/{id}")
      {_, _, schema} = BillionSend.Test.Contract.Operation.success(op)
      example = Contract.example(schema)
      published = Map.update!(example, "unsubscribe_page", &Map.merge(&1, @page))
      Mock.respond(mock, "GET", "/domains/{id}", 200, json: published)

      assert {:ok, %{"unsubscribe_page" => page}} = BillionSend.Domains.get(client, id())
      assert Map.take(page, Map.keys(@page)) == @page
      assert page["powered_by"] == nil and page["powered_by_effective"] == true
    end
  end

  describe "a broadcast and its dormant contacts" do
    test "create and update send include_dormant and dormant_check" do
      {client, mock} = client()

      assert {:ok, _} =
               BillionSend.Broadcasts.create(client, %{
                 segment_id: id(),
                 from: "Acme <news@acme.dev>",
                 subject: "Spring news",
                 html: "<p>Hello</p>",
                 include_dormant: true,
                 dormant_check: false
               })

      assert {:ok, _} =
               BillionSend.Broadcasts.update(client, id(), %{
                 include_dormant: false,
                 dormant_check: true
               })

      assert [create, update] = Mock.calls(mock)
      assert %{"include_dormant" => true, "dormant_check" => false} = create.body
      assert update.body == %{"include_dormant" => false, "dormant_check" => true}
      assert Mock.violations(mock) == []
    end

    test "get reads both fields as booleans" do
      {client, mock} = client()
      op = Contract.operation("GET", "/broadcasts/{id}")
      {_, _, schema} = BillionSend.Test.Contract.Operation.success(op)

      published =
        schema
        |> Contract.example()
        |> Map.merge(%{"include_dormant" => false, "dormant_check" => true})

      Mock.respond(mock, "GET", "/broadcasts/{id}", 200, json: published)

      assert {:ok, %{"include_dormant" => false, "dormant_check" => true}} =
               BillionSend.Broadcasts.get(client, id())
    end
  end
end
