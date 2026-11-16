# Detection now skips Investment and Crypto accounts, but filtering the source
# query does nothing to series that were already detected. Pipeline#run!
# generates occurrences for every active series regardless of origin, so
# without this an existing install keeps its phantom bills -- and, worse, keeps
# counting retirement contributions as recurring income.
#
# `ended` is the tombstone status the detector reads and will not recreate.
class RetireRecurringSeriesOnInvestmentAccounts < ActiveRecord::Migration[7.2]
  # Deliberately two COMMITTED steps rather than one transaction: status first,
  # so the window in which a concurrent request can generate for these series
  # is as small as possible.
  #
  # It is NOT zero. OccurrenceGenerator#generate! tests the in-memory series
  # object, so a request that loaded the row before the UPDATE committed can
  # still insert scheduled occurrences after the DELETE below. The cleanup is
  # therefore best-effort, and that is fine: BillsController#payable_series_ids
  # scopes to active/inactive, so occurrences on an ended series are never
  # listed, and the next generate! call loads current state and returns 0. Any
  # row that slips through is invisible and self-limiting.
  #
  # Closing it completely would mean serialising the request path -- a
  # behaviour change well outside what this migration should carry.
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

    # 2. Then drop the re-generatable future (best-effort, see above). Scoped to
    #    every target series, not just the ones retired above, so a
    #    partially-applied run -- or a row inserted by a racing request -- is
    #    cleaned up on a re-run. Paid, skipped and missed rows are history.
    execute <<~SQL
      DELETE FROM recurring_occurrences
      WHERE recurring_transaction_id IN (#{quoted_ids})
        AND status = 'scheduled'
    SQL

    say "Retired #{retired} recurring series detected from investment/crypto accounts"
  end

  # Genuinely irreversible: the prior status of each series and the deleted
  # occurrences are not recorded anywhere, so a rollback cannot restore them.
  # Returning successfully would drop the version from schema_migrations and
  # report a rollback that did not happen.
  def down
    raise ActiveRecord::IrreversibleMigration,
          "Retired investment-account series cannot be restored"
  end
end
