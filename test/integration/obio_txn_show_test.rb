require "test_helper"

class ObioTransactionShowTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @item = OpenBankingIoItem.create!(family: @family, name: "OBIO",
      api_base_url: "https://open-banking.io", api_key: "k", private_key: "p")
    @provider_account = @item.open_banking_io_accounts.create!(
      account_id: "a1", name: "Everyday", currency: "EUR")
    AccountProvider.create!(account: @account, provider: @provider_account)
  end

  test "an open-banking.io transaction detail page renders" do
    entry = OpenBankingIoEntry::Processor.new({
      id: "tx_show", currency: "EUR", credit_debit_indicator: "DBIT", status: "BOOK",
      booking_date: Date.current.to_s, amount: "42.50", creditor_name: "Netto",
      remittance_information: "Groceries", creditor_agent_bic: "NDEADKKK"
    }, open_banking_io_account: @provider_account).process

    assert entry, "the entry must import"
    get transaction_url(entry)
    assert_response :success
    assert_match "Netto", response.body
  end

  test "a pending open-banking.io transaction detail page renders" do
    entry = OpenBankingIoEntry::Processor.new({
      id: "tx_pend", currency: "EUR", credit_debit_indicator: "DBIT", status: "PDNG",
      booking_date: Date.current.to_s, amount: "10.00", creditor_name: "Hotel"
    }, open_banking_io_account: @provider_account).process

    get transaction_url(entry)
    assert_response :success
  end

  test "an id-less open-banking.io transaction detail page renders" do
    entry = OpenBankingIoEntry::Processor.new({
      currency: "EUR", credit_debit_indicator: "CRDT", status: "BOOK",
      booking_date: Date.current.to_s, amount: "99.00", debtor_name: "Employer"
    }, open_banking_io_account: @provider_account).process

    get transaction_url(entry)
    assert_response :success
  end
end
