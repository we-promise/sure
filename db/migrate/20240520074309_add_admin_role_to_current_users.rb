class AddAdminRoleToCurrentUsers < ActiveRecord::Migration[7.2]
  # Scope to the migration so loading the production User model — which declares
  # enums for columns added by later migrations (e.g. ui_layout) — does not
  # abort a fresh `db:migrate` run on an empty database. Inherit from
  # ActiveRecord::Base (not ApplicationRecord) so any future concerns,
  # callbacks, or default scopes added to ApplicationRecord cannot re-introduce
  # the same loading problem this migration is meant to avoid.
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  def up
    MigrationUser.update_all(role: "admin")
  end
end
