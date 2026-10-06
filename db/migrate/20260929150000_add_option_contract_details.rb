class AddOptionContractDetails < ActiveRecord::Migration[8.1]
  def change
    add_column :securities, :option_type, :string
    add_column :securities, :underlying_ticker, :string
    add_column :securities, :strike_price, :decimal, precision: 19, scale: 6
    add_column :securities, :expiration_date, :date
    add_column :securities, :contract_multiplier, :integer, null: false, default: 1

    add_check_constraint :securities, "option_type IS NULL OR option_type IN ('call', 'put')", name: "chk_securities_option_type"
    add_check_constraint :securities, "contract_multiplier > 0", name: "chk_securities_contract_multiplier"

    add_column :trades, :contract_multiplier, :integer, null: false, default: 1
    add_check_constraint :trades, "contract_multiplier > 0", name: "chk_trades_contract_multiplier"
  end
end
