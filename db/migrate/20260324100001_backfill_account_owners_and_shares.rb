class BackfillAccountOwnersAndShares < ActiveRecord::Migration[7.2]
  def up
    # Existing families keep current behavior: all accounts shared
    Family.update_all(default_account_sharing: "shared")

    # For each family, assign all accounts to the admin (or first user)
    Family.find_each do |family|
      admin = family.users.find_by(role: %w[admin super_admin]) || family.users.order(:created_at).first
      next unless admin

      family.accounts.where(owner_id: nil).update_all(owner_id: admin.id)

      # Create shares for non-owner members (preserves current full-access behavior)
      family.users.where.not(id: admin.id).find_each do |member|
        family.accounts.find_each do |account|
          AccountShare.create!(
            account: account,
            user: member,
            permission: "full_control",
            include_in_finances: true
          )
        rescue ActiveRecord::RecordInvalid
          # Skip duplicates
        end
      end
    end

    # Owner is enforced at the model level via before_validation callback
    # Keeping nullable at DB level for backward compatibility with tests/seeds
  end

  def down
    Account.update_all(owner_id: nil)
    AccountShare.delete_all
  end
end
