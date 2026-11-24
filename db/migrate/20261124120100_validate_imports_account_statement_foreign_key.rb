# Validates the key the previous migration added NOT VALID. VALIDATE CONSTRAINT
# takes SHARE UPDATE EXCLUSIVE on imports, so imports keep being written while
# the existing rows are checked.
class ValidateImportsAccountStatementForeignKey < ActiveRecord::Migration[8.1]
  def up
    validate_foreign_key :imports, :account_statements
  end

  # Postgres cannot mark a validated key NOT VALID again; re-adding it NOT VALID
  # restores the state the previous migration left.
  def down
    remove_foreign_key :imports, :account_statements
    add_foreign_key :imports, :account_statements, validate: false
  end
end
