class AddHashColumnsForSecurity < ActiveRecord::Migration[7.2]
  def change
    # Invitations - for token hashing
    add_column :invitations, :token_digest, :string
    add_index :invitations, :token_digest, unique: true, where: "token_digest IS NOT NULL"

    # InviteCodes - for token hashing
    add_column :invite_codes, :token_digest, :string
    add_index :invite_codes, :token_digest, unique: true, where: "token_digest IS NOT NULL"

    # Sessions - for IP hashing
    add_column :sessions, :ip_address_digest, :string
    add_index :sessions, :ip_address_digest
  end
end
