defmodule BillionSend.Pagination do
  @moduledoc """
  Every item of a cursor-paginated list, as a lazy `Stream`.

  Lists are newest first: `after` takes the last id of a page and pages toward
  older items, `before` takes the first id and pages toward newer ones. The
  stream raises the same errors the `!` functions do. A page without a data
  array raises `BillionSend.Error` (`application_error`, no status) at once; a
  page that has more but whose item to continue from has no id hands out its
  items first, then raises.
  """

  defp cursor(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp cursor(_), do: nil

  @doc false
  # `fetch.(after, before)` answers one page: {:ok, %{"data" => [...], "has_more" => bool}}.
  def stream(fetch, after_id, before_id) do
    backward = before_id != nil and after_id == nil

    Stream.resource(
      fn -> {after_id, before_id, true} end,
      fn
        {_, _, false} = state ->
          {:halt, state}

        {after_id, before_id, true} ->
          page = BillionSend.Client.unwrap!(fetch.(after_id, before_id))

          items =
            case page do
              %{"data" => items} when is_list(items) -> items
              _ -> raise BillionSend.Error, message: "The list page has no data array"
            end

          cond do
            page["has_more"] != true or items == [] ->
              {items, {after_id, before_id, false}}

            true ->
              case cursor(if(backward, do: hd(items), else: List.last(items))) do
                nil -> {items, :no_cursor}
                id when backward -> {items, {after_id, id, true}}
                id -> {items, {id, before_id, true}}
              end
          end

        :no_cursor ->
          raise BillionSend.Error,
            message: "The last item of the list page has no id to continue from"
      end,
      fn _ -> :ok end
    )
  end
end
