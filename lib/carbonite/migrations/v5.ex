# SPDX-License-Identifier: Apache-2.0

defmodule Carbonite.Migrations.V5 do
  @moduledoc false

  use Ecto.Migration
  use Carbonite.Migrations.Version
  alias Carbonite.Migrations.V4

  @type prefix :: binary()

  @type up_option :: {:carbonite_prefix, prefix()}

  @spec create_capture_changes_procedure(prefix()) :: :ok
  def create_capture_changes_procedure(prefix) do
    """
    CREATE OR REPLACE FUNCTION #{prefix}.capture_changes() RETURNS TRIGGER AS
    $body$
    DECLARE
      trigger_row #{prefix}.triggers;
      change_row #{prefix}.changes;
      pk_source RECORD;
      col_name VARCHAR;
      pk_col_val VARCHAR;
      old_field RECORD;
      old_field_jsonb JSONB;
    BEGIN
      /* load trigger config */
      SELECT *
        INTO trigger_row
        FROM #{prefix}.triggers
        WHERE table_prefix = TG_TABLE_SCHEMA AND table_name = TG_TABLE_NAME;

      IF
        (trigger_row.mode = 'ignore' AND (trigger_row.override_xact_id IS NULL OR trigger_row.override_xact_id != pg_current_xact_id())) OR
        (trigger_row.mode = 'capture' AND trigger_row.override_xact_id = pg_current_xact_id())
      THEN
        RETURN NULL;
      END IF;

      /* instantiate change row */
      change_row = ROW(
        NEXTVAL('#{prefix}.changes_id_seq'),
        pg_current_xact_id(),
        LOWER(TG_OP::TEXT),
        TG_TABLE_SCHEMA::TEXT,
        TG_TABLE_NAME::TEXT,
        NULL,
        NULL,
        '{}',
        NULL,
        NULL
      );

      /* build table_pk */
      IF trigger_row.primary_key_columns != '{}' THEN
        IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
          pk_source := NEW;
        ELSIF (TG_OP = 'DELETE') THEN
          pk_source := OLD;
        END IF;

        change_row.table_pk := '{}';

        FOREACH col_name IN ARRAY trigger_row.primary_key_columns LOOP
          EXECUTE 'SELECT $1.' || col_name || '::TEXT' USING pk_source INTO pk_col_val;
          change_row.table_pk := change_row.table_pk || pk_col_val;
        END LOOP;
      END IF;

      /* fill in changed data */
      IF (TG_OP = 'UPDATE') THEN
        change_row.data = to_jsonb(NEW.*) - trigger_row.excluded_columns;
        change_row.changed_from = '{}'::JSONB;

        FOR old_field_jsonb
        IN SELECT jsonb_build_object(key, value)
        FROM jsonb_each(to_jsonb(OLD.*) - trigger_row.excluded_columns)
        LOOP
          IF NOT change_row.data @> old_field_jsonb THEN
            change_row.changed_from := change_row.changed_from || old_field_jsonb;
          END IF;
        END LOOP;

        change_row.changed := ARRAY(SELECT jsonb_object_keys(change_row.changed_from));

        IF change_row.changed = '{}' THEN
          /* All changed fields are ignored. Skip this update. */
          RETURN NULL;
        END IF;

        /* Persisting the old data is opt-in, discard if not configured. */
        IF trigger_row.store_changed_from IS FALSE THEN
          change_row.changed_from := NULL;
        END IF;
      ELSIF (TG_OP = 'DELETE') THEN
        change_row.data = to_jsonb(OLD.*) - trigger_row.excluded_columns;
      ELSIF (TG_OP = 'INSERT') THEN
        change_row.data = to_jsonb(NEW.*) - trigger_row.excluded_columns;
      END IF;

      /* filtered columns */
      FOREACH col_name IN ARRAY trigger_row.filtered_columns LOOP
        change_row.data = jsonb_set(change_row.data, ('{' || col_name || '}')::TEXT[], jsonb('"[FILTERED]"'));
      END LOOP;

      /* insert, fail gracefully unless transaction record present or NEXTVAL has never been called */
      BEGIN
        change_row.transaction_id = CURRVAL('#{prefix}.transactions_id_seq');

        /* verify that xact_id matches */
        IF NOT
          EXISTS(
            SELECT 1 FROM #{prefix}.transactions
            WHERE id = change_row.transaction_id AND xact_id = change_row.transaction_xact_id
          )
        THEN
          RAISE USING ERRCODE = 'foreign_key_violation';
        END IF;

        INSERT INTO #{prefix}.changes VALUES (change_row.*);
      EXCEPTION WHEN foreign_key_violation OR object_not_in_prerequisite_state THEN
          RAISE '% on table %.% without prior INSERT into #{prefix}.transactions',
            TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME USING ERRCODE = 'foreign_key_violation';
      END;

      RETURN NULL;
    END;
    $body$
    LANGUAGE plpgsql;
    """
    |> squish_and_execute()

    :ok
  end

  @impl true
  @spec up([up_option()]) :: :ok
  def up(opts) do
    prefix = Keyword.get(opts, :carbonite_prefix, default_prefix())

    lock_changes(prefix)

    # ------------- `changed_from` ---------------

    alter table(:changes, prefix: prefix) do
      add(:changed_from, :jsonb, null: true)
    end

    alter table(:triggers, prefix: prefix) do
      add(:store_changed_from, :boolean, default: false, null: false)
    end

    # ------------- Capture Function -------------

    create_capture_changes_procedure(prefix)

    :ok
  end

  @type down_option :: {:carbonite_prefix, prefix()}

  @impl true
  @spec down([down_option()]) :: :ok
  def down(opts) do
    prefix = Keyword.get(opts, :carbonite_prefix, default_prefix())

    lock_changes(prefix)

    # ------------- `changed_from` ------------

    alter table(:changes, prefix: prefix) do
      remove(:changed_from)
    end

    alter table(:triggers, prefix: prefix) do
      remove(:store_changed_from)
    end

    # ------------ Restore functions -------------

    V4.create_capture_changes_procedure(prefix)

    :ok
  end

  defp lock_changes(prefix) do
    squish_and_execute("LOCK TABLE #{prefix}.changes IN EXCLUSIVE MODE;")
  end
end