-- Compare application tables and sequence state while all application writers
-- are stopped. Include identity sequences and the is_called flag.
CREATE TEMP TABLE installer_pg_manifest(kind text, name text, value text);
DO $$
DECLARE item record; observed text;
BEGIN
  FOR item IN
    SELECT n.nspname, c.relname, c.relkind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
      AND c.relkind IN ('r', 'p', 'S')
    ORDER BY n.nspname, c.relname
  LOOP
    IF item.relkind = 'S' THEN
      EXECUTE format('SELECT last_value::text || '':'' || is_called::text FROM %I.%I', item.nspname, item.relname) INTO observed;
    ELSE
      EXECUTE format('SELECT count(*)::text FROM %I.%I', item.nspname, item.relname) INTO observed;
    END IF;
    INSERT INTO installer_pg_manifest VALUES
      (item.relkind, format('%I.%I', item.nspname, item.relname), observed);
  END LOOP;
END $$;
SELECT coalesce(json_agg(row_to_json(m) ORDER BY kind, name), '[]'::json)
FROM installer_pg_manifest m;
