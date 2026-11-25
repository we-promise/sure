# One derived import per source import: an AI tool that finishes after its
# request gave up must not create a second import when the client retries.
class AddSourceImportIdToImports < ActiveRecord::Migration[8.1]
  def change
    add_reference :imports, :source_import, type: :uuid, foreign_key: { to_table: :imports }, index: false
    add_index :imports, :source_import_id, unique: true, where: "source_import_id IS NOT NULL",
                                           name: "idx_imports_source_import_unique"
  end
end
