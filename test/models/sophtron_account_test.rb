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

  test "database rejects an unsupported balance sign override" do
    account = build_sophtron_account
    account.balance_sign_override = "unsupported"

    assert_raises ActiveRecord::StatementInvalid do
      account.save!(validate: false)
    end
  end

  test "failed sync scheduling rolls back the override and applied balance" do
    sophtron_account = build_sophtron_account
    account = accounts(:credit_card)
    AccountProvider.create!(account: account, provider: sophtron_account)
    original_balance = account.balance
    original_cash_balance = account.cash_balance
    original_anchor = account.current_anchor_balance
    Account.any_instance.stubs(:sync_later).raises(StandardError, "sync scheduling failed")

    assert_raises StandardError do
      sophtron_account.apply_balance_sign_override!("credit")
    end

    assert_nil sophtron_account.reload.balance_sign_override
    assert_equal original_balance, account.reload.balance
    assert_equal original_cash_balance, account.cash_balance
    assert_equal original_anchor, account.current_anchor_balance
  end

  private
    def build_sophtron_account
      item = families(:dylan_family).sophtron_items.create!(
        name: "Sophtron Connection",
        user_id: "developer-user",
        access_key: Base64.strict_encode64("secret-key")
      )

      item.sophtron_accounts.create!(
        account_id: "card-override",
        name: "Card",
        currency: "USD",
        balance: 25
      )
    end
end
