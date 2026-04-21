defmodule Tractor.Condition do
  @moduledoc """
  Recursive-descent condition parser/evaluator for edge routing.
  """

  @type outcome :: map()
  @type literal :: String.t() | float()
  @type ast ::
          {:or, ast(), ast()}
          | {:and, ast(), ast()}
          | {:not, ast()}
          | {:cmp, atom(), String.t(), literal()}
          | {:shorthand, :accept | :reject | :partial_success}

  @type token ::
          :lparen
          | :rparen
          | :and
          | :or
          | :not
          | :eq
          | :neq
          | :lt
          | :lte
          | :gt
          | :gte
          | :contains
          | {:word, String.t()}
          | {:string, String.t()}

  @comparison_tokens [:eq, :neq, :lt, :lte, :gt, :gte, :contains]
  @special_chars ["(", ")", "&", "|", "!", "=", "<", ">", "\""]

  @spec valid?(String.t() | nil) :: boolean()
  def valid?(condition) do
    case parse(condition) do
      {:ok, _expr} -> true
      {:error, _reason} -> false
    end
  end

  @spec match?(String.t() | nil, outcome(), map()) :: boolean()
  def match?(condition, outcome, context \\ %{}) do
    case parse(condition) do
      {:ok, nil} -> false
      {:ok, expr} -> eval(expr, outcome, context)
      {:error, _reason} -> false
    end
  end

  @spec parse(String.t() | nil) :: {:ok, ast() | nil} | {:error, atom()}
  def parse(nil), do: {:ok, nil}

  def parse(condition) when is_binary(condition) do
    condition = String.trim(condition)

    with false <- condition == "",
         {:ok, tokens} <- tokenize(condition),
         {:ok, expr, []} <- parse_expr(tokens) do
      {:ok, expr}
    else
      true -> {:ok, nil}
      {:ok, _expr, _trailing} -> {:error, :invalid_condition}
      {:error, _reason} -> {:error, :invalid_condition}
    end
  end

  defp parse_expr(tokens), do: parse_or(tokens)

  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens) do
      parse_or_rest(left, rest)
    end
  end

  defp parse_or_rest(left, [:or | rest]) do
    with {:ok, right, rest} <- parse_and(rest) do
      parse_or_rest({:or, left, right}, rest)
    end
  end

  defp parse_or_rest(left, rest), do: {:ok, left, rest}

  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_not(tokens) do
      parse_and_rest(left, rest)
    end
  end

  defp parse_and_rest(left, [:and | rest]) do
    with {:ok, right, rest} <- parse_not(rest) do
      parse_and_rest({:and, left, right}, rest)
    end
  end

  defp parse_and_rest(left, rest), do: {:ok, left, rest}

  defp parse_not([:not | rest]) do
    with {:ok, expr, rest} <- parse_not(rest) do
      {:ok, normalize_not(expr), rest}
    end
  end

  defp parse_not(tokens), do: parse_atom(tokens)

  defp parse_atom([:lparen | rest]) do
    case parse_expr(rest) do
      {:ok, expr, [:rparen | rest]} -> {:ok, expr, rest}
      _other -> {:error, :invalid_condition}
    end
  end

  defp parse_atom([{:word, word} | rest]) do
    cond do
      shorthand?(word) and (rest == [] or hd(rest) not in @comparison_tokens) ->
        {:ok, {:shorthand, shorthand_atom(word)}, rest}

      rest == [] ->
        {:error, :invalid_condition}

      true ->
        parse_comparison(word, rest)
    end
  end

  defp parse_atom(_tokens), do: {:error, :invalid_condition}

  defp parse_comparison(key, [op | rest]) when op in @comparison_tokens do
    with {:ok, literal, rest} <- parse_literal(rest) do
      {:ok, {:cmp, comparison_op(op), key, literal}, rest}
    end
  end

  defp parse_comparison(_key, _tokens), do: {:error, :invalid_condition}

  defp parse_literal([{:string, value} | rest]), do: {:ok, value, rest}
  defp parse_literal([{:word, value} | rest]), do: {:ok, parse_word_literal(value), rest}
  defp parse_literal(_tokens), do: {:error, :invalid_condition}

  defp tokenize(binary), do: tokenize(binary, [])

  defp tokenize(<<>>, tokens), do: {:ok, Enum.reverse(tokens)}
  defp tokenize(<<" ", rest::binary>>, tokens), do: tokenize(rest, tokens)
  defp tokenize(<<"\t", rest::binary>>, tokens), do: tokenize(rest, tokens)
  defp tokenize(<<"\n", rest::binary>>, tokens), do: tokenize(rest, tokens)
  defp tokenize(<<"\r", rest::binary>>, tokens), do: tokenize(rest, tokens)
  defp tokenize(<<"&&", rest::binary>>, tokens), do: tokenize(rest, [:and | tokens])
  defp tokenize(<<"||", rest::binary>>, tokens), do: tokenize(rest, [:or | tokens])
  defp tokenize(<<"!=", rest::binary>>, tokens), do: tokenize(rest, [:neq | tokens])
  defp tokenize(<<"<=", rest::binary>>, tokens), do: tokenize(rest, [:lte | tokens])
  defp tokenize(<<">=", rest::binary>>, tokens), do: tokenize(rest, [:gte | tokens])
  defp tokenize(<<"(", rest::binary>>, tokens), do: tokenize(rest, [:lparen | tokens])
  defp tokenize(<<")", rest::binary>>, tokens), do: tokenize(rest, [:rparen | tokens])
  defp tokenize(<<"!", rest::binary>>, tokens), do: tokenize(rest, [:not | tokens])
  defp tokenize(<<"=", rest::binary>>, tokens), do: tokenize(rest, [:eq | tokens])
  defp tokenize(<<"<", rest::binary>>, tokens), do: tokenize(rest, [:lt | tokens])
  defp tokenize(<<">", rest::binary>>, tokens), do: tokenize(rest, [:gt | tokens])

  defp tokenize(<<"\"", rest::binary>>, tokens) do
    with {:ok, value, rest} <- take_string(rest, "") do
      tokenize(rest, [{:string, value} | tokens])
    end
  end

  defp tokenize(binary, tokens) do
    {word, rest} = take_word(binary, "")

    cond do
      word == "" -> {:error, :invalid_condition}
      word == "contains" -> tokenize(rest, [:contains | tokens])
      true -> tokenize(rest, [{:word, word} | tokens])
    end
  end

  defp take_string(<<>>, _acc), do: {:error, :invalid_condition}

  defp take_string(<<"\\\"", rest::binary>>, acc), do: take_string(rest, acc <> "\"")
  defp take_string(<<"\\\\", rest::binary>>, acc), do: take_string(rest, acc <> "\\")
  defp take_string(<<"\\n", rest::binary>>, acc), do: take_string(rest, acc <> "\n")
  defp take_string(<<"\\r", rest::binary>>, acc), do: take_string(rest, acc <> "\r")
  defp take_string(<<"\\t", rest::binary>>, acc), do: take_string(rest, acc <> "\t")
  defp take_string(<<"\"", rest::binary>>, acc), do: {:ok, acc, rest}

  defp take_string(<<char::utf8, rest::binary>>, acc),
    do: take_string(rest, acc <> <<char::utf8>>)

  defp take_word(<<>>, acc), do: {acc, ""}

  defp take_word(<<char::utf8, _rest::binary>> = binary, acc) do
    grapheme = <<char::utf8>>

    cond do
      String.trim(grapheme) == "" ->
        {acc, binary}

      grapheme in @special_chars ->
        {acc, binary}

      true ->
        <<_::utf8, rest::binary>> = binary
        take_word(rest, acc <> grapheme)
    end
  end

  defp eval({:or, left, right}, outcome, context) do
    eval(left, outcome, context) || eval(right, outcome, context)
  end

  defp eval({:and, left, right}, outcome, context) do
    eval(left, outcome, context) && eval(right, outcome, context)
  end

  defp eval({:not, expr}, outcome, context), do: not eval(expr, outcome, context)

  defp eval({:shorthand, :accept}, outcome, _context) do
    value_for("preferred_label", outcome, %{}) == "accept"
  end

  defp eval({:shorthand, :reject}, outcome, _context) do
    value_for("preferred_label", outcome, %{}) == "reject"
  end

  defp eval({:shorthand, :partial_success}, outcome, _context) do
    value_for("outcome", outcome, %{}) == "partial_success"
  end

  defp eval({:cmp, op, key, literal}, outcome, context) do
    lhs = value_for(key, outcome, context)
    rhs = literal_to_string(literal)

    case op do
      :eq -> lhs == rhs
      :neq -> lhs != rhs
      :contains -> String.contains?(lhs, rhs)
      :lt -> numeric_compare(lhs, rhs, &Kernel.</2)
      :lte -> numeric_compare(lhs, rhs, &Kernel.<=/2)
      :gt -> numeric_compare(lhs, rhs, &Kernel.>/2)
      :gte -> numeric_compare(lhs, rhs, &Kernel.>=/2)
    end
  end

  defp value_for("outcome", outcome, _context), do: stringify(outcome_value(outcome, :status))

  defp value_for("preferred_label", outcome, _context),
    do: stringify(outcome_value(outcome, :preferred_label))

  defp value_for("context." <> key, _outcome, context) do
    context_value(context, key)
    |> stringify()
  end

  defp value_for(_key, _outcome, _context), do: ""

  defp outcome_value(outcome, key) do
    Map.get(outcome, key) || Map.get(outcome, to_string(key))
  end

  defp context_value(context, key) do
    case Map.fetch(context, key) do
      {:ok, value} -> value
      :error -> dotted_value(context, String.split(key, "."))
    end
  end

  defp dotted_value(value, []), do: value

  defp dotted_value(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> dotted_value(value, rest)
      :error -> ""
    end
  end

  defp dotted_value(list, [key | rest]) when is_list(list) do
    case Integer.parse(key) do
      {index, ""} -> list |> Enum.at(index, "") |> dotted_value(rest)
      _other -> ""
    end
  end

  defp dotted_value(_value, _path), do: ""

  defp numeric_compare(lhs, rhs, comparator) do
    with {lhs_number, ""} <- Float.parse(lhs),
         {rhs_number, ""} <- Float.parse(rhs) do
      comparator.(lhs_number, rhs_number)
    else
      _other -> false
    end
  end

  defp parse_word_literal(word) do
    case Float.parse(word) do
      {number, ""} -> number
      _other -> word
    end
  end

  defp literal_to_string(value) when is_float(value) do
    :erlang.float_to_binary(value, [:compact, decimals: 15])
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp literal_to_string(value), do: stringify(value)

  defp normalize_not({:not, expr}), do: expr
  defp normalize_not(expr), do: {:not, expr}

  defp comparison_op(:eq), do: :eq
  defp comparison_op(:neq), do: :neq
  defp comparison_op(:lt), do: :lt
  defp comparison_op(:lte), do: :lte
  defp comparison_op(:gt), do: :gt
  defp comparison_op(:gte), do: :gte
  defp comparison_op(:contains), do: :contains

  defp shorthand?(word), do: word in ["accept", "reject", "partial_success"]

  defp shorthand_atom("accept"), do: :accept
  defp shorthand_atom("reject"), do: :reject
  defp shorthand_atom("partial_success"), do: :partial_success

  defp stringify(nil), do: ""

  defp stringify(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.trim_leading("Elixir.")

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_boolean(value), do: to_string(value)
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_float(value), do: literal_to_string(value)
  defp stringify(value), do: inspect(value)
end
