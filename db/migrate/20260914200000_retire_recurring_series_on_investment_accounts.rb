# Detection now skips Investment and Crypto accounts, but filtering the source
# query does nothing to series that were already detected. Pipeline#run!
# generates occurrences for every active series regardless of origin, so
# without this an existing install keeps its phantom bills -- and, worse, keeps
# counting retirement contributions as recurring income.
#
# `ended` is the tombstone status the detector reads and will not recreate.
class RetireRecurringSeriesOnInvestmentAccounts < ActiveRecord::Migration[7.2]
  # Deliberately two COMMITTED steps rather than one transaction.
  #
  # OccurrenceGenerator#generate! returns early unless the series is active, and
  # BillsController only lists occurrences for active/inactive series. Once the
  # status change is committed, no request can add another scheduled occurrence
  # for these series, so the cleanup that follows is final and needs no
  # cross-process lock. Doing it the other way round would leave a window in
  # which a concurrent Bills request re-materialises a row behind the delete.
  disable_ddl_transaction!

  NON_BILLABLE = %w[Investment Crypto].freeze

  def up
    quoted_types = NON_BILLABLE.map { |t| connection.quote(t) }.join(",")

    target_ids = select_values(<<~SQL)
      SELECT recurring_transactions.id
      FROM recurring_transactions
      JOIN accounts ON accounts.id = recurring_transactions.account_id
      WHERE accounts.accountable_type IN (#{quoted_types})
    SQL

    return if target_ids.empty?

    quoted_ids = target_ids.map { |id| connection.quote(id) }.join(",")

    # 1. Close the generation path first.
    retired = update(<<~SQL)
      UPDATE recurring_transactions
      SET status = 'ended', updated_at = NOW()
      WHERE id IN (#{quoted_ids})
        AND status <> 'ended'
    SQL

    # 2. Then drop the re-generatable future. Scoped to every target series, not
    #    just the ones retired above, so a partially-applied run cleans up fully
    #    on retry. Paid, skipped and missed rows are history and stay.
    execute <<~SQL
      DELETE FROM recurring_occurrences
      WHERE recurring_transaction_id IN (#{quoted_ids})
        AND status = 'scheduled'
    SQL

    say "Retired #{retired} recurring series detected from investment/crypto accounts"
  end

  # Irreversible by design: restoring these would recreate exactly the phantom
  # bills and income this removes, and the detector will not regenerate them.
  def down
    say "No-op: retired investment-account series are not restored"
  end
end
