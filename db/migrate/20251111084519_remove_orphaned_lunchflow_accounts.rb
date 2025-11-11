class RemoveOrphanedLunchflowAccounts < ActiveRecord::Migration[7.2]
  def up
    # Find all LunchflowAccount records that don't have an associated account_provider
    # These are "orphaned" accounts that were created during sync but never actually
    # imported/linked by the user due to old behavior that saved all accounts
    orphaned_accounts = LunchflowAccount.left_outer_joins(:account_provider)
                                        .where(account_providers: { id: nil })

    orphaned_count = orphaned_accounts.count

    if orphaned_count > 0
      Rails.logger.info "Removing #{orphaned_count} orphaned LunchflowAccount records (not linked via account_provider)"

      # Delete orphaned accounts
      orphaned_accounts.destroy_all

      Rails.logger.info "Successfully removed #{orphaned_count} orphaned LunchflowAccount records"
    else
      Rails.logger.info "No orphaned LunchflowAccount records found to remove"
    end
  end

  def down
    # Cannot restore orphaned accounts that were deleted
    # These were unused accounts from old behavior that shouldn't have been created
    Rails.logger.info "Cannot restore orphaned LunchflowAccount records (data migration is irreversible)"
  end
end
