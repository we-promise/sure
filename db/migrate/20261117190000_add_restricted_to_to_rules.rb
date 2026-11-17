# A rule saved by a non-admin acts only on accounts that user can write
# (Rule#restrict_to_editor). Existing rules stay family-wide (null).
class AddRestrictedToToRules < ActiveRecord::Migration[8.1]
  def change
    add_reference :rules, :restricted_to, type: :uuid, foreign_key: { to_table: :users }, index: true
  end
end
