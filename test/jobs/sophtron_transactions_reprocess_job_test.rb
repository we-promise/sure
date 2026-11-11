require "test_helper"

class SophtronTransactionsReprocessJobTest < ActiveJob::TestCase
  setup do
    item = families(:dylan_family).sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key")
    )
    @sophtron_account = item.sophtron_accounts.create!(
      account_id: "card-reprocess",
      name: "Card",
      currency: "USD",
      balance: 25,
      raw_transactions_payload: [
        { id: "charge", amount: "40", currency: "USD", date: "2026-05-01", merchant: "Coffee Shop" }
      ]
    )
    @account = accounts(:credit_card)
    AccountProvider.create!(account: @account, provider: @sophtron_account)
  end

  test "re-signs transactions imported before the convention was detected and syncs the account" do
    SophtronAccount::Transactions::Processor.new(@sophtron_account).process
    entry = @account.entries.find_by!(external_id: "sophtron_charge")
    assert_equal BigDecimal("-40"), entry.amount

    @sophtron_account.update!(balance_sign_override: "debt", lender_signed: true)
    Account.any_instance.expects(:sync_later).once

    SophtronTransactionsReprocessJob.perform_now(@sophtron_account)

    assert_equal BigDecimal("40"), entry.reload.amount
  end

  test "does nothing once the account is unlinked" do
    @sophtron_account.account_provider.destroy!
    SophtronAccount::Transactions::Processor.expects(:new).never

    SophtronTransactionsReprocessJob.perform_now(@sophtron_account.reload)
  end
end
