# SPDX-License-Identifier: Apache-2.0

defmodule Carbonite.TestRepo.Migrations.InstallCarbonite do
  use Ecto.Migration

  def change do
    Carbonite.Migrations.install_schema()
    Carbonite.Migrations.install_trigger(:rabbits, excluded_columns: ["age"])
  end
end