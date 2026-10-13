defmodule AiInPractice.Reports.Canonical do
  @moduledoc """
  The canonical JSON encoding that the assessor report's signature covers
  (#707), so a verifier can re-encode the payload it extracts and check the
  signature against the same bytes.

    * object keys sorted by their UTF-8 bytes, at every depth;
    * no whitespace between tokens;
    * strings as `Jason` escapes them (`"`, `\\`, control characters;
      everything else literal UTF-8);
    * integers, booleans and `null` as usual.

  **Floats are refused.** Their text form differs between encoders, and the
  payload has no use for them: the report's internal levels and confidence
  are never in it, and everything else is words. Atom keys and atom values
  (other than `true`, `false` and `nil`) are written as strings, so a payload
  built in Elixir and the same payload decoded from JSON encode identically.
  """

  @type json ::
          nil | boolean() | integer() | String.t() | [json()] | %{optional(String.t()) => json()}

  @doc """
  The canonical bytes of `term`. Raises `ArgumentError` on a float or
  anything else JSON cannot hold.
  """
  @spec encode!(term()) :: binary()
  def encode!(term), do: term |> encode() |> IO.iodata_to_binary()

  defp encode(nil), do: "null"
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(n) when is_integer(n), do: Integer.to_string(n)
  defp encode(s) when is_binary(s), do: Jason.encode_to_iodata!(s)
  defp encode(a) when is_atom(a), do: a |> Atom.to_string() |> encode()

  defp encode(f) when is_float(f),
    do: raise(ArgumentError, "floats are not allowed in a signed payload")

  defp encode(list) when is_list(list),
    do: ["[", list |> Enum.map(&encode/1) |> Enum.intersperse(","), "]"]

  defp encode(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> {key(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> check_unique()
      |> Enum.map(fn {k, v} -> [encode(k), ":", encode(v)] end)

    ["{", Enum.intersperse(pairs, ","), "}"]
  end

  defp encode(other),
    do: raise(ArgumentError, "cannot encode a #{type(other)} in a signed payload")

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k) and not is_nil(k) and not is_boolean(k), do: Atom.to_string(k)
  defp key(_k), do: raise(ArgumentError, "object keys must be strings or atoms")

  # `%{:a => 1, "a" => 2}` would otherwise encode a duplicate key.
  defp check_unique(pairs) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(Enum.uniq(keys)) == length(keys),
      do: pairs,
      else: raise(ArgumentError, "duplicate object key")
  end

  defp type(%{__struct__: mod}), do: inspect(mod)
  defp type(t) when is_tuple(t), do: "tuple"
  defp type(_), do: "value"
end
