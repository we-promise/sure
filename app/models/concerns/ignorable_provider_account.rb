# A provider account the user skipped during setup, for instance one that belongs
# to someone else but is visible through the same credentials. The row stays so
# the choice survives re-syncs, but importers neither fetch nor store anything
# for it. Linking it to a Sure account clears the flag (see AccountProvider).
#
# Including models need an `ignored` boolean column and an `account_provider`
# association, and define `ignored_snapshot_reset` with the fetched data to drop.
module IgnorableProviderAccount
  extend ActiveSupport::Concern

  included do
    # Unlinked accounts that still need a setup decision.
    scope :needs_setup, -> { left_joins(:account_provider).where(account_providers: { id: nil }, ignored: false) }
  end

  # Returns false, and changes nothing, when the account is linked: unlink it first.
  def ignore!
    return false if account_provider.present?

    update!(ignored: true, **ignored_snapshot_reset)
  end

  # Runs the block (a snapshot write) under the row lock unless the account is
  # ignored by then, so data fetched before an ignore! is not written after it.
  # An ignore! arriving meanwhile waits for the lock. Returns false when skipped.
  def write_unless_ignored
    return yield if new_record?

    with_lock { ignored? ? false : yield }
  end
end
