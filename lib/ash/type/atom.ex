defmodule Ash.Type.Atom do
  @moduledoc """
  A type used for storing atoms.

  For safety reasons, it uses `String.to_existing_atom/1`, which means
  that the atom should exist in your application before reading a record
  with that atom.
  """
  use Ash.Type

  @impl true
  def storage_type, do: :string

  @impl true
  def cast_input(value) when is_atom(value), do: {:ok, value}
  def cast_input(_), do: :error

  @impl true
  def cast_stored(value), do: {:ok, String.to_existing_atom(value)}

  @impl true
  def dump_to_native(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  def dump_to_native(_), do: :error
end
