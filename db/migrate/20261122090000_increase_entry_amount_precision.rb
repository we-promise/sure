# frozen_string_literal: true

class IncreaseEntryAmountPrecision < ActiveRecord::Migration[8.1]
  # Amounts a crypto account can hold end to end. The balance history feeds
  # accounts.balance back through Balance::Materializer, so widening only the
  # account column would still round on the next sync.
  COLUMNS = [
    [ :entries, :amount, { null: false } ],
    [ :accounts, :balance, {} ],
    [ :accounts, :cash_balance, { default: 0.0 } ],
    [ :transfers, :amount, { default: 0.0, null: false } ],
    [ :balances, :balance, { null: false } ],
    [ :balances, :cash_adjustments, { default: 0.0, null: false } ],
    [ :balances, :cash_balance, { default: 0.0 } ],
    [ :balances, :cash_inflows, { default: 0.0, null: false } ],
    [ :balances, :cash_outflows, { default: 0.0, null: false } ],
    [ :balances, :net_market_flows, { default: 0.0, null: false } ],
    [ :balances, :non_cash_adjustments, { default: 0.0, null: false } ],
    [ :balances, :non_cash_inflows, { default: 0.0, null: false } ],
    [ :balances, :non_cash_outflows, { default: 0.0, null: false } ],
    [ :balances, :start_cash_balance, { default: 0.0, null: false } ],
    [ :balances, :start_non_cash_balance, { default: 0.0, null: false } ]
  ].freeze

  # Postgres will not alter a column a generated column depends on, so these
  # are dropped and re-added around the base-column change.
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
    drop_generated_columns
    COLUMNS.each { |table, column, options| change_column table, column, :decimal, precision: 34, scale: 18, **options }
    add_generated_columns(precision: 34, scale: 18)
  end

  def down
    if COLUMNS.any? { |table, column, _| excess_precision?(table, column) }
      raise ActiveRecord::IrreversibleMigration,
        "Reducing transaction amounts to four decimal places would discard stored cryptocurrency precision"
    end

    drop_generated_columns
    COLUMNS.each { |table, column, options| change_column table, column, :decimal, precision: 19, scale: 4, **options }
    add_generated_columns(precision: 19, scale: 4)
  end

  private
    def drop_generated_columns
      GENERATED_COLUMNS.each_key { |column| remove_column :balances, column }
    end

    def add_generated_columns(precision:, scale:)
      GENERATED_COLUMNS.each do |column, expression|
        add_column :balances, column, :virtual,
          type: :decimal, precision: precision, scale: scale, as: expression, stored: true
      end
    end

    def excess_precision?(table, column)
      connection.select_value(
        "SELECT 1 FROM #{table} WHERE #{column} IS NOT NULL AND #{column} <> round(#{column}, 4) LIMIT 1"
      ).present?
    end
end
