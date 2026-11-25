# An import with a statement is visible only to those who can view the
# statement. Nullifying the reference when the statement goes made the import
# visible to the whole family, and the model's check for imports cannot stop an
# import committed between that check and the DELETE. The database refuses the
# DELETE instead, and its foreign key locks serialize it with import creation.
#
# NO ACTION rather than RESTRICT: both refuse the DELETE, but only NO ACTION
# raises the foreign key violation Rails reports as InvalidForeignKey.
#
# The new key is added NOT VALID, so the ACCESS EXCLUSIVE lock on imports lasts
# only for the swap. It is enforced on new rows and deletes at once; the next
# migration validates the existing rows under a lock that lets writes through.
class RestrictStatementDeletionWhileImportsCarryIt < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :imports, :account_statements
    add_foreign_key :imports, :account_statements, validate: false
  end

  def down
    remove_foreign_key :imports, :account_statements
    add_foreign_key :imports, :account_statements, on_delete: :nullify
  end
end
