defmodule Aegis.Render do
  @moduledoc "ASCII map renderer, for eyeballing geometry and simulator traces."

  alias Aegis.Map

  def ascii(%Map{} = m) do
    header = "    " <> (0..(m.wc - 1) |> Enum.map(&rem(&1, 10)) |> Enum.join())

    rows =
      for cy <- 0..(m.hc - 1) do
        body =
          for cx <- 0..(m.wc - 1), into: "" do
            if Map.walkable_cell?(m, cx, cy), do: ".", else: "#"
          end

        label = String.pad_leading("#{cy * trunc(m.cell)}", 3)
        label <> " " <> body
      end

    Enum.join([header | rows], "\n")
  end

  @doc "Overlay a list of `{pos, char}` markers on the map."
  def overlay(%Map{} = m, markers) do
    cells =
      :maps.from_list(
        Enum.map(markers, fn {{x, y}, ch} ->
          {{trunc(x / m.cell), trunc(y / m.cell)}, ch}
        end)
      )

    rows =
      for cy <- 0..(m.hc - 1) do
        for cx <- 0..(m.wc - 1), into: "" do
          case :maps.get({cx, cy}, cells, nil) do
            nil -> if Map.walkable_cell?(m, cx, cy), do: ".", else: "#"
            ch -> ch
          end
        end
      end

    Enum.join(rows, "\n")
  end
end
