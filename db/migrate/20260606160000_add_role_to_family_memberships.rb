class AddRoleToFamilyMemberships < ActiveRecord::Migration[7.2]
  def change
    add_column :family_memberships, :role, :string, null: false, default: "member"
    add_index :family_memberships, :role
  end
end
