defmodule Ash.Error.Forbidden do
  @moduledoc "Raised when authorization for an action fails"
  defexception [
    :resource,
    :scenarios,
    :authorization_steps,
    :facts,
    :strict_check_facts,
    :state,
    no_steps_configured?: false
  ]

  # TODO: Use better logic to format this

  alias Ash.Authorization.Clause

  # TODO: Put `resource` in the pkey info so that we can display what kind of record it is

  def message(%{no_steps_configured?: true}) do
    "One of the authorizations required had no authorization steps configured."
  end

  # We know that each group of authorization steps shares the same relationship
  def message(error) do
    header = "forbidden:\n\n"

    explained_steps =
      case error.state do
        %{data: data} ->
          explain_steps_with_data(error.authorization_steps, error.facts, data)

        _ ->
          explain_steps(error.authorization_steps, error.facts)
      end

    explained_facts = explain_facts(error.facts, error.strict_check_facts || %{})

    main_message =
      header <>
        "Facts Gathered\n" <>
        indent(explained_facts) <> "\n\nAuthorization Steps:\n" <> indent(explained_steps)

    main_message <> "\n\nScenarios:\n" <> indent(explain_scenarios(error.scenarios))
  end

  defp explain_scenarios(scenarios) when scenarios in [nil, []] do
    """
    No scenarios found. Under construction.
    Eventually, scenarios will explain what data you could change to make the request possible.
    """
  end

  defp explain_scenarios(scenarios) do
    """
    #{Enum.count(scenarios)} found. Under construction.
    Eventually, scenarios will explain what data you could change to make the request possible.
    """
  end

  defp explain_steps_with_data(sets_of_authorization_steps, facts, data) do
    sets_of_authorization_steps
    |> Enum.map_join("\n---\n", fn [{_, %{relationship: relationship, resource: resource}} | _] =
                                     steps ->
      title =
        if relationship == [] do
          inspect(resource)
        else
          # Enum.join(relationship, ".") <> " - #{inspect(resource)}"
          raise "Ack, can't do relationships now!"
        end

      authorization_steps_legend =
        steps
        |> Enum.with_index()
        |> Enum.map_join("\n", fn {{step, check}, index} ->
          "#{index + 1}| " <>
            to_string(step) <> ": " <> check.check_module.describe(check.check_opts)
        end)

      pkey = Ash.primary_key(resource)

      # TODO: data has to change with relationships
      data_info =
        data
        |> Enum.map(fn item ->
          formatted =
            item
            |> Map.take(pkey)
            |> format_pkey()

          {formatted, Map.take(item, pkey)}
        end)
        |> add_header_line(title)
        |> pad()
        |> add_step_info(steps, facts)

      authorization_steps_legend <> "\n\n" <> data_info <> "\n"
    end)
  end

  defp add_step_info([header | rest], steps, facts) do
    key = Enum.join(1..Enum.count(steps), "|")

    header <>
      "|" <>
      key <>
      "|\n" <>
      do_add_step_info(rest, steps, facts)
  end

  defp do_add_step_info(pkeys, steps, facts) do
    Enum.map_join(pkeys, "\n", fn {pkey_line, pkey} ->
      steps
      |> Enum.reduce({true, pkey_line}, fn
        {_step, _clause}, {false, string} ->
          {false, string <> "|~"}

        {step, clause}, {true, string} ->
          status =
            case Clause.find(facts, %{clause | pkey: pkey}) do
              {:ok, value} -> value
              _ -> nil
            end

          mark = step_to_mark(step, status)

          new_mark =
            if mark == "↓" do
              "→"
            else
              mark
            end

          continue? = new_mark not in ["✓", "✗"]

          {continue?, string <> "|" <> new_mark}
      end)
      |> elem(1)
      |> Kernel.<>("|")
    end)
  end

  defp add_header_line(lines, title) do
    [title | lines]
  end

  defp pad(lines) do
    longest =
      lines
      |> Enum.map(fn
        {line, _pkey} ->
          String.length(line)

        line ->
          String.length(line)
      end)
      |> Enum.max()

    Enum.map(
      lines,
      fn
        {line, pkey} ->
          length = String.length(line)

          {line <> String.duplicate(" ", longest - length), pkey}

        line ->
          length = String.length(line)

          line <> String.duplicate(" ", longest - length)
      end
    )
  end

  defp explain_facts(facts, strict_check_facts) do
    facts
    |> Map.drop([true, false])
    |> Enum.group_by(fn {clause, _status} ->
      clause.pkey
    end)
    |> Enum.sort_by(fn {pkey, _} -> not is_nil(pkey) end)
    |> Enum.map_join("\n---\n", fn {pkey, clauses_and_statuses} ->
      title = format_pkey(pkey) <> " facts"

      contents =
        Enum.map_join(clauses_and_statuses, fn {clause, status} ->
          gets_star? =
            Clause.find(strict_check_facts, clause) in [
              {:ok, true},
              {:ok, false}
            ]

          star =
            if gets_star? do
              " ⭑"
            else
              ""
            end

          relationship = clause.relationship
          mod = clause.check_module
          opts = clause.check_opts

          if clause.relationship == [] do
            status_to_mark(status) <> " " <> mod.describe(opts) <> star
          else
            status_to_mark(status) <>
              " " <> Enum.join(relationship, ".") <> " " <> mod.describe(opts) <> star
          end
        end)

      title <> ":\n" <> indent(contents)
    end)
  end

  defp format_pkey(nil), do: "Global"

  defp format_pkey(pkey) do
    if Enum.count(pkey) == 1 do
      pkey |> Enum.at(0) |> elem(1) |> to_string()
    else
      Enum.map_join(pkey, ",", fn {key, value} -> to_string(key) <> ":" <> to_string(value) end)
    end
  end

  defp status_to_mark(true), do: "✓"
  defp status_to_mark(false), do: "✗"
  defp status_to_mark(:unknowable), do: "!"
  defp status_to_mark(nil), do: "?"

  defp indent(string) do
    string
    |> String.split("\n")
    |> Enum.map(fn line -> "  " <> line end)
    |> Enum.join("\n")
  end

  defp explain_steps(sets_of_authorization_steps, facts) do
    Enum.map_join(sets_of_authorization_steps, "---", fn authorization_steps ->
      authorization_steps
      |> Enum.map(fn {step, clause} ->
        status =
          case Clause.find(facts, clause) do
            {:ok, value} -> value
            _ -> nil
          end

        status_mark = status_to_mark(status)

        mark = status_mark <> " " <> step_to_mark(step, status)

        mod = clause.check_module
        opts = clause.check_opts
        relationship = clause.relationship

        if relationship == [] do
          mark <>
            " | " <> to_string(step) <> ": " <> mod.describe(opts)
        else
          mark <>
            " | " <>
            to_string(step) <>
            ": #{Enum.join(relationship, ".")} " <>
            mod.describe(opts)
        end
      end)
      |> Enum.join("\n")
    end)
  end

  defp step_to_mark(:authorize_if, true), do: "✓"
  defp step_to_mark(:authorize_if, false), do: "↓"
  defp step_to_mark(:authorize_if, _), do: "↓"

  defp step_to_mark(:forbid_if, true), do: "✗"
  defp step_to_mark(:forbid_if, false), do: "↓"
  defp step_to_mark(:forbid_if, _), do: "✗"

  defp step_to_mark(:authorize_unless, true), do: "↓"
  defp step_to_mark(:authorize_unless, false), do: "✓"
  defp step_to_mark(:authorize_unless, _), do: "↓"

  defp step_to_mark(:forbid_unless, true), do: "↓"
  defp step_to_mark(:forbid_unless, false), do: "✗"
  defp step_to_mark(:forbid_unless, _), do: "✗"
end
