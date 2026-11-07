# How each PDF import was read (2e plan): the "Read as" the user asked for, the way that was used
# and the model that read it, and the extraction's checks. Auto starts from the last way that
# passed for the same account and model.
class AddPdfReadingToImports < ActiveRecord::Migration[8.1]
  def change
    add_column :imports, :read_as, :string
    add_column :imports, :read_with, :string
    add_column :imports, :read_model, :string
    add_column :imports, :extraction_checks, :jsonb
    add_index :imports, %i[account_id read_model updated_at], where: "type = 'PdfImport' AND read_with IS NOT NULL",
                                                              name: "index_pdf_imports_on_account_and_read_model"
  end
end
