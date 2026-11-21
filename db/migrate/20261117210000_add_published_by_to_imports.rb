# Who published an import, so the rules it brings are restricted to them
# (Family::DataImporter). Null for imports published before this.
class AddPublishedByToImports < ActiveRecord::Migration[8.1]
  def change
    add_reference :imports, :published_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
  end
end
