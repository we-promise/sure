class RelaxSimplefinItemInstitutionConstraints < ActiveRecord::Migration[7.2]
  def up
    # SimpleFin doesn't guarantee institution metadata on first fetch,
    # so these fields must be optional.
    change_column_null :simplefin_items, :institution_id, true
    change_column_null :simplefin_items, :institution_name, true
  end

  def down
    # Restoring NOT NULL could break existing rows that legitimately have no institution metadata.
    # We keep this reversible but conservative: only set NOT NULL if no NULLs exist.
    if execute("SELECT COUNT(*) FROM simplefin_items WHERE institution_id IS NULL").first["count"].to_i == 0
      change_column_null :simplefin_items, :institution_id, false
    end

    if execute("SELECT COUNT(*) FROM simplefin_items WHERE institution_name IS NULL").first["count"].to_i == 0
      change_column_null :simplefin_items, :institution_name, false
    end
  end
end
