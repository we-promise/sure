class AddSimplefinCredentialRevision < ActiveRecord::Migration[8.1]
  def up
    add_column :simplefin_items, :credential_revision, :bigint, null: false, default: 0
    add_check_constraint :simplefin_items, "credential_revision >= 0", name: "chk_simplefin_credential_revision"

    execute <<~SQL
      CREATE FUNCTION advance_simplefin_credential_revision() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.access_url IS DISTINCT FROM OLD.access_url THEN
          NEW.credential_revision := OLD.credential_revision + 1;
        ELSE
          NEW.credential_revision := OLD.credential_revision;
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER simplefin_credential_revision
      BEFORE UPDATE ON simplefin_items
      FOR EACH ROW EXECUTE FUNCTION advance_simplefin_credential_revision();
    SQL
  end

  def down
    execute "DROP TRIGGER simplefin_credential_revision ON simplefin_items"
    execute "DROP FUNCTION advance_simplefin_credential_revision()"
    remove_check_constraint :simplefin_items, name: "chk_simplefin_credential_revision"
    remove_column :simplefin_items, :credential_revision
  end
end
