defmodule BillionSend.Pagination do
  @moduledoc """
  Every item of a cursor-paginated list, as a lazy `Stream`.

  Lists are newest first: `after` takes the last id of a page and pages toward
  older items, `before` takes the first id and pages toward newer ones. The
  stream raises the same errors the `!` functions do.
  """

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
          items = page["data"] || []
          more = page["has_more"] == true and items != []

          next =
            cond do
              not more -> {after_id, before_id, false}
              backward -> {after_id, to_string(hd(items)["id"]), true}
              true -> {to_string(List.last(items)["id"]), before_id, true}
            end

          {items, next}
      end,
      fn _ -> :ok end
    )
  end
end
