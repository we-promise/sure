class RemoveUniqueEmailFamilyIndexFromInvitations < ActiveRecord::Migration[7.2]
  def change
    remove_index :invitations, [ :email, :family_id ], name: "index_invitations_on_email_and_family_id"
    add_index :invitations, [ :email, :family_id ],
              name: "index_invitations_on_email_and_family_id_pending",
              unique: true,
              where: "accepted_at IS NULL"
  end
end
