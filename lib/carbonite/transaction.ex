# SPDX-License-Identifier: Apache-2.0

defmodule Carbonite.Transaction do
  @moduledoc """
  A `Carbonite.Transaction` is the binding link between change records of tables.

  As such, it contains a set of optional metadata that describes the transaction.
  """

  use Ecto.Schema

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          meta: map(),
          processed_at: DateTime.t(),
          inserted_at: DateTime.t(),
          changes: Ecto.Association.NotLoaded.t() | [Carbonite.Change.t()]
        }

  schema "transactions" do
    field(:id, :integer, primary_key: true)
    field(:meta, :map)
    field(:processed_at, :utc_datetime_usec)

    timestamps(updated_at: false)

    has_many(:changes, Carbonite.Change, references: :id)
  end
end