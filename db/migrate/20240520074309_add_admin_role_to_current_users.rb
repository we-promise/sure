class AddAdminRoleToCurrentUsers < ActiveRecord::Migration[7.2]
  # Scope to the migration so loading the production User model — which declares
  # enums for columns added by later migrations (e.g. ui_layout) — does not
  # abort a fresh `db:migrate` run on an empty database.
  class MigrationUser < ApplicationRecord
    self.table_name = "users"
  end

  def up
    MigrationUser.update_all(role: "admin")
  end
end
