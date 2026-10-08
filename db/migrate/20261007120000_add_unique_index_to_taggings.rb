# Nothing stopped a tag being applied twice to the same object, and some
# installations already hold such duplicates. Remove them, keeping the
# oldest row of each, then add a unique index so they cannot come back.
#
# The index is partial because both taggable columns are nullable: a row
# with no taggable is not a tagging of anything, so it is left alone.
# NULLS NOT DISTINCT (PostgreSQL 15+) is what makes the index hold when
# taggable_type is missing; by default Postgres treats two NULLs as
# different keys and would let that duplicate through. PARTITION BY groups
# NULLs together, so the dedupe sees those rows too.
#
# Writers are locked out from before the DELETE until the index exists. The
# DELETE alone takes only ROW EXCLUSIVE, which lets other inserts through, so
# a duplicate written between it and CREATE INDEX would fail the index build.
# SHARE ROW EXCLUSIVE blocks concurrent writes and is held to the end of the
# migration's transaction; a transaction never conflicts with its own locks,
# so the DELETE still runs.
class AddUniqueIndexToTaggings < ActiveRecord::Migration[8.1]
  def up
    execute "LOCK TABLE taggings IN SHARE ROW EXCLUSIVE MODE"

    execute <<~SQL
      DELETE FROM taggings
      WHERE id IN (
        SELECT id FROM (
          SELECT id, ROW_NUMBER() OVER (
            PARTITION BY tag_id, taggable_type, taggable_id
            ORDER BY created_at, id
          ) AS position
          FROM taggings
          WHERE taggable_id IS NOT NULL
        ) ranked
        WHERE position > 1
      )
    SQL

    add_index :taggings, [ :tag_id, :taggable_type, :taggable_id ],
      name: "index_taggings_unique",
      unique: true,
      nulls_not_distinct: true,
      where: "taggable_id IS NOT NULL",
      if_not_exists: true
  end

  # The deleted duplicates are not kept anywhere, so rolling back only
  # drops the index.
  def down
    remove_index :taggings, name: "index_taggings_unique", if_exists: true
  end
end
