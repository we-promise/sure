# One statement can back more than one import, so an entry needs to say which
# import's reading marked it: discarding that reading releases only its marks.
class AddReconciliationOwnerToEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :entries, :reconciled_by_import_id, :uuid
  end
end
