# frozen_string_literal: true

class RepairPdfImportOwnedColumn < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:account_statements, :pdf_import_owned)
      add_column :account_statements, :pdf_import_owned, :boolean, null: false, default: false
    end

    execute <<~SQL
      UPDATE account_statements
      SET pdf_import_owned = TRUE
      WHERE pdf_import_owned = FALSE
        AND account_id IS NULL
        AND content_type = 'application/pdf'
        AND EXISTS (
          SELECT 1
          FROM imports
          WHERE imports.account_statement_id = account_statements.id
            AND imports.type = 'PdfImport'
        )
    SQL
  end

  # Keep the column introduced by the preceding feature migration in place.
  def down
  end
end
