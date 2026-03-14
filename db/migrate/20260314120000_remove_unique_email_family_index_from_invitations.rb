class RemoveUniqueEmailFamilyIndexFromInvitations < ActiveRecord::Migration[8.0]
  def change
    remove_index :invitations, name: "index_invitations_on_email_and_family_id"
  end
end
