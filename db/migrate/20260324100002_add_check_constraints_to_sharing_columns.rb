class AddCheckConstraintsToSharingColumns < ActiveRecord::Migration[7.2]
  def change
    add_check_constraint :families, "default_account_sharing IN ('shared', 'private')", name: "chk_families_default_account_sharing"
    add_check_constraint :account_shares, "permission IN ('full_control', 'read_write', 'read_only')", name: "chk_account_shares_permission"
  end
end
