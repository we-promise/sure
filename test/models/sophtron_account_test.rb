require "test_helper"

class SophtronAccountTest < ActiveSupport::TestCase
  test "upsert_sophtron_snapshot stores owning item institution metadata fallback" do
    item = families(:dylan_family).sophtron_items.create!(
      name: "Sophtron Connection",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key"),
      institution_name: "Apple / Goldman Sachs",
      user_institution_id: "ui-apple"
    )

    account = item.sophtron_accounts.build
    account.upsert_sophtron_snapshot!(
      account_id: "card-1",
      account_name: "Juan",
      currency: "USD",
      balance: "1947.18"
    )

    assert_equal "Apple / Goldman Sachs", account.institution_metadata["name"]
    assert_equal "ui-apple", account.institution_metadata["user_institution_id"]
  end

  test "processor preserves Sophtron balance signs for credit cards and loans" do
    item = families(:dylan_family).sophtron_items.create!(
      name: "Sophtron Connection",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key")
    )

    [ CreditCard, Loan ].each do |accountable_class|
      sophtron_account = item.sophtron_accounts.create!(
        name: accountable_class.name,
        account_id: "#{accountable_class.name.downcase}-1",
        currency: "USD",
        balance: -1_947.18
      )
      account = families(:dylan_family).accounts.create!(
        name: accountable_class.name,
        currency: "USD",
        balance: 0,
        cash_balance: 0,
        accountable: accountable_class.new
      )
      AccountProvider.create!(account: account, provider: sophtron_account)

      SophtronAccount::Processor.new(sophtron_account).process

      assert_equal BigDecimal("-1947.18"), account.reload.balance
      assert_equal BigDecimal("-1947.18"), account.cash_balance
    end
  end
end
