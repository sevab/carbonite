Postgrex.Types.define(
  Carbonite.PostgrexTypes,
  [Carbonite.Postgrex.Xid8 | Ecto.Adapters.Postgres.extensions()],
  json: Jason
)