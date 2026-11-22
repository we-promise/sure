# A transaction is pending when any provider in Transaction::PENDING_PROVIDERS
# flags it in `extra`, by the same rule as Transaction.pending_sql. Stored as a
# column so the query planner keeps statistics on it: on the expression it
# estimates almost no rows survive the filter and plans every later join for
# one row.
#
# The expression is spelled out rather than built from the model, so this
# migration keeps producing the column it shipped with. Changing the provider
# list or the false values needs a new migration that redefines the column;
# a test compares the column with the model's rule.
class AddPendingToTransactions < ActiveRecord::Migration[8.1]
  FALSE_VALUES = "'0', 'f', 'F', 'false', 'FALSE', 'off', 'OFF', ''"
  PROVIDERS = %w[akahu enable_banking financekit lunchflow mercury monobank plaid redbark simplefin up].freeze

  def change
    pending = PROVIDERS.map { |provider| "COALESCE(extra -> '#{provider}' ->> 'pending', '') NOT IN (#{FALSE_VALUES})" }.join(" OR ")

    add_column :transactions, :pending, :virtual, type: :boolean, as: "(#{pending})", stored: true
  end
end
