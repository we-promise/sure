class AddAdminRoleToCurrentUsers < ActiveRecord::Migration[7.2]
  def up
    # Raw SQL on purpose — do NOT replace with `User.update_all`.
    #
    # This data migration must not load the live User model. User declares
    # `enum :ui_layout`, backed by a column added in a much later migration
    # (20251030140000_add_ui_layout_to_users). On a fresh `db:migrate` replay
    # the column does not exist yet when this runs, so loading the class raises
    # "Undeclared attribute type for enum 'ui_layout'", aborting this and every
    # subsequent migration and leaving fresh clones unable to bootstrap.
    #
    # `users.role` is a string column whose `admin` enum value is stored as the
    # literal "admin", so this is equivalent to the original model call.
    execute "UPDATE users SET role = 'admin'"
  end
end
