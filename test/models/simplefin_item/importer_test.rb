require "test_helper"

class SimplefinItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SimpleFIN Importer Test",
      access_url: "https://example.com/access"
    )
    @importer = SimplefinItem::Importer.new(@item, simplefin_provider: nil)
  end

  test "normalizes numeric-string epoch balance-date for importer upserts" do
    epoch_string = Time.utc(2026, 6, 17, 12, 34, 56).to_i.to_s

    parsed = @importer.send(:normalize_balance_date, epoch_string)

    assert_equal Time.at(epoch_string.to_i).utc, parsed
  end

  test "balances-only import persists a negative provider credit-card debt as positive" do
    credit_card = accounts(:credit_card)
    simplefin_account = @item.simplefin_accounts.create!(
      name: "Amex",
      account_id: "sf_amex_1",
      account_type: "credit",
      currency: "USD",
      current_balance: -1911.72
    )
    credit_card.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Amex",
      balance: -1911.72,
      currency: "USD"
    })

    assert_equal 1911.72, credit_card.reload.balance
    assert_equal 1911.72, credit_card.cash_balance
  end
end
