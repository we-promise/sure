# A reread claim is specific to one job attempt, so a delayed job cannot clear a
# later reading or a publish. Tool drafts remember their source PDF so two
# extracts of one statement cannot leave overlapping live drafts.
class AddRereadClaimToImports < ActiveRecord::Migration[8.1]
  def change
    add_column :imports, :reread_token, :string
    add_column :imports, :source_pdf_import_id, :uuid
  end
end
