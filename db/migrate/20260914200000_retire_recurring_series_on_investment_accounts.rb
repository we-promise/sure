# Detection now skips Investment and Crypto accounts, but filtering the source
# query does nothing to series that were already detected. Pipeline#run!
# generates occurrences for every active series regardless of where it came
# from, so without this an existing install keeps its phantom bills -- and,
# worse, keeps counting retirement contributions as recurring income.
#
# `ended` is the tombstone status the detector reads and will not recreate, so
# retiring them here is durable. Open (scheduled) occurrences are dropped as
# well; paid/skipped/missed rows are history and stay.
class RetireRecurringSeriesOnInvestmentAccounts < ActiveRecord::Migration[7.2]
  NON_BILLABLE = %w[Investment Crypto].freeze

  def up
    series_ids = execute(<<~SQL).values.flatten
      SELECT recurring_transactions.id
      FROM recurring_transactions
      JOIN accounts ON accounts.id = recurring_transactions.account_id
      WHERE accounts.accountable_type IN (#{NON_BILLABLE.map { |t| connection.quote(t) }.join(',')})
        AND recurring_transactions.status <> 'ended'
    SQL

    return if series_ids.empty?

    quoted = series_ids.map { |id| connection.quote(id) }.join(",")

    execute <<~SQL
      DELETE FROM recurring_occurrences
      WHERE recurring_transaction_id IN (#{quoted})
        AND status = 'scheduled'
    SQL

    execute <<~SQL
      UPDATE recurring_transactions
      SET status = 'ended', updated_at = NOW()
      WHERE id IN (#{quoted})
    SQL

    say "Retired #{series_ids.size} recurring series detected from investment/crypto accounts"
  end

  # Irreversible by design: re-activating these would restore exactly the
  # phantom bills and income this removes, and the detector will not recreate
  # them. Nothing of value is lost -- real bills are unaffected.
  def down
    say "No-op: retired investment-account series are not restored"
  end
end
