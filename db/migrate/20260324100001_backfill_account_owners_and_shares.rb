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
      member_ids = family.users.where.not(id: admin.id).pluck(:id)
      account_ids = family.accounts.pluck(:id)

      if member_ids.any? && account_ids.any?
        records = member_ids.product(account_ids).map do |user_id, account_id|
          { user_id: user_id, account_id: account_id, permission: "full_control",
            include_in_finances: true, created_at: Time.current, updated_at: Time.current }
        end

        AccountShare.upsert_all(records, unique_by: %i[account_id user_id])
      end
    end

    # Owner is enforced at the model level via before_validation callback
    # Keeping nullable at DB level for backward compatibility with tests/seeds
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
