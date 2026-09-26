class AllowLargePdfAccountStatements < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :account_statements, name: "chk_account_statements_byte_size_max"
    add_column :account_statements, :pdf_import_owned, :boolean, null: false, default: false

    execute <<~SQL
      UPDATE account_statements
      SET pdf_import_owned = TRUE
      WHERE account_id IS NULL
        AND content_type = 'application/pdf'
        AND EXISTS (
          SELECT 1
          FROM imports
          WHERE imports.account_statement_id = account_statements.id
            AND imports.type = 'PdfImport'
        )
    SQL
  end

  def down
    remove_column :account_statements, :pdf_import_owned
    add_check_constraint :account_statements,
      "byte_size <= 26214400",
      name: "chk_account_statements_byte_size_max",
      validate: false
  end
end
