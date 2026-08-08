class AddUniqueIndexToTaggings < ActiveRecord::Migration[7.2]
  def up
    # Existing duplicate (tag_id, taggable_type, taggable_id) rows would fail
    # the unique index below. They're safe to drop outright: Pocket's
    # tagged_transaction_total already dedupes on entries.id/amount, so extra
    # tagging rows for the same pair never changed a pocket's recomputed total.
    execute <<~SQL
      DELETE FROM taggings
      WHERE id IN (
        SELECT id FROM (
          SELECT id, ROW_NUMBER() OVER (
            PARTITION BY tag_id, taggable_type, taggable_id
            ORDER BY created_at, id
          ) AS row_num
          FROM taggings
        ) ranked
        WHERE row_num > 1
      )
    SQL

    add_index :taggings, [ :tag_id, :taggable_type, :taggable_id ],
      unique: true,
      name: "index_taggings_on_tag_and_taggable_unique"
  end

  def down
    remove_index :taggings, name: "index_taggings_on_tag_and_taggable_unique"
  end
end
