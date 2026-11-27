# frozen_string_literal: true

class IncreaseEntryAmountPrecision < ActiveRecord::Migration[8.1]
  # Amounts a crypto account can hold end to end. The balance history feeds
  # accounts.balance back through Balance::Materializer, so widening only the
  # account column would still round on the next sync.
  COLUMNS = {
    entries: %i[amount],
    accounts: %i[balance cash_balance],
    transfers: %i[amount],
    balances: %i[
      balance cash_adjustments cash_balance cash_inflows cash_outflows
      net_market_flows non_cash_adjustments non_cash_inflows non_cash_outflows
      start_cash_balance start_non_cash_balance
    ]
  }.freeze

  # Postgres will not alter a column a generated column depends on, so these
  # are dropped and re-added in the same ALTER TABLE as the type change.
  GENERATED_COLUMNS = {
    start_balance: "start_cash_balance + start_non_cash_balance",
    end_cash_balance: "start_cash_balance + ((cash_inflows - cash_outflows) * flows_factor) + cash_adjustments",
    end_non_cash_balance: "start_non_cash_balance + ((non_cash_inflows - non_cash_outflows) * flows_factor) + net_market_flows + non_cash_adjustments",
    end_balance: <<~SQL.squish
      (
        start_cash_balance +
        ((cash_inflows - cash_outflows) * flows_factor) +
        cash_adjustments
      ) + (
        start_non_cash_balance +
        ((non_cash_inflows - non_cash_outflows) * flows_factor) +
        net_market_flows +
        non_cash_adjustments
      )
    SQL
  }.freeze

  def up
    change_precision(precision: 34, scale: 18)
  end

  def down
    # Held until the migration commits, so no write lands between the check
    # and the narrowing. The ALTER TABLE takes this lock anyway.
    execute "LOCK TABLE #{COLUMNS.keys.map { |table| quote_table_name(table) }.join(", ")} IN ACCESS EXCLUSIVE MODE"

    if COLUMNS.any? { |table, columns| columns.any? { |column| excess_precision?(table, column) } }
      raise ActiveRecord::IrreversibleMigration,
        "Reducing transaction amounts to four decimal places would discard stored cryptocurrency precision"
    end

    change_precision(precision: 19, scale: 4)
  end

  private
    # One ALTER TABLE per table, so each table is rewritten once.
    def change_precision(precision:, scale:)
      COLUMNS.each do |table, columns|
        change_table table, bulk: true do |t|
          generated = table == :balances ? GENERATED_COLUMNS : {}

          generated.each_key { |column| t.remove column }
          columns.each { |column| t.change column, :decimal, precision: precision, scale: scale }
          generated.each do |column, expression|
            t.virtual column, type: :decimal, precision: precision, scale: scale, as: expression, stored: true
          end
        end
      end
    end

    def excess_precision?(table, column)
      connection.select_value(
        "SELECT 1 FROM #{table} WHERE #{column} IS NOT NULL AND #{column} <> round(#{column}, 4) LIMIT 1"
      ).present?
    end
end
