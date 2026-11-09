# frozen_string_literal: true

class AddCashSettingsToSharesightAccounts < ActiveRecord::Migration[8.1]
  def change
    change_table :sharesight_accounts, bulk: true do |t|
      # Where the cash lives: with the broker, in a settlement account, or not tracked.
      t.string :cash_mode, default: "broker", null: false
      t.references :settlement_account, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.date :settlement_starts_on
      t.integer :settlement_window_days, default: 7, null: false

      # Where dividends and distributions get paid.
      t.string :dividend_mode, default: "with_cash", null: false
      t.references :dividend_account, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }

      # Top-ups from a bank account that's already in Sure.
      t.references :funding_account, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.jsonb :funding_match_terms, default: [], null: false

      # Broker cash Sharesight can't see, as you saw it on a date.
      t.decimal :cash_anchor_amount, precision: 19, scale: 4
      t.date :cash_anchor_on

      t.date :sync_start_date
    end
  end
end
