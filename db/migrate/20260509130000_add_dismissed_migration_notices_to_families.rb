# Adds an array column for tracking which MigrationNotice keys this family
# has dismissed. The MigrationNotice registry filters notices a family has
# already acknowledged so the action-required banner stops showing once the
# operator has performed the corresponding deploy step.
class AddDismissedMigrationNoticesToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :dismissed_migration_notices, :string,
               array: true, default: [], null: false
  end
end
