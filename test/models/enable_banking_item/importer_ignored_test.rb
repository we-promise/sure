require "test_helper"

class EnableBankingItem::ImporterIgnoredTest < ActiveSupport::TestCase
  setup do
    @item = EnableBankingItem.create!(
      family: families(:dylan_family),
      name: "Test EB",
      country_code: "ES",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now
    )
    @ignored = @item.enable_banking_accounts.create!(name: "Theirs", uid: "hash_theirs", account_id: "uid-old", currency: "EUR")
    @ignored.ignore!
    @importer = EnableBankingItem::Importer.new(@item, enable_banking_provider: mock("enable_banking_provider"))
  end

  test "a sync refreshes only the session UID of an ignored account" do
    @importer.stubs(:fetch_session_data).returns(
      accounts: [ { uid: "uid-new", identification_hash: "hash_theirs", currency: "EUR", name: "Renamed" } ]
    )

    assert_no_changes -> { @ignored.reload.attributes.except("account_id", "updated_at") } do
      @importer.import
    end
    assert_equal "uid-new", @ignored.account_id
  end

  test "an account ignored before a re-authorization syncs with the new session UID once linked" do
    @item.stubs(:enable_banking_provider).returns(stub(create_session: {
      session_id: "sess-new",
      accounts: [ { uid: "uid-new", identification_hash: "hash_theirs", currency: "EUR", name: "Theirs" } ]
    }))
    @item.complete_authorization(code: "code")
    account = Account.create!(family: @item.family, name: "Theirs", balance: 0, currency: "EUR", accountable: Depository.new)
    AccountProvider.create!(account: account, provider: @ignored)

    provider = mock("enable_banking_provider")
    provider.expects(:get_account_transactions).with(has_entry(account_id: "uid-new")).at_least_once.returns(transactions: [])
    provider.expects(:get_account_balances).with(has_entry(account_id: "uid-new")).returns(balances: [])
    importer = EnableBankingItem::Importer.new(@item.reload, enable_banking_provider: provider)
    # GET /sessions can list accounts as bare session UIDs, which carry no identification hash.
    importer.stubs(:fetch_session_data).returns(accounts: [ "uid-new" ])

    importer.import
  end

  test "an account unlinked and ignored while its transactions are being fetched is not written back" do
    mine = linked_account("hash_mine")
    skip_mine = -> { unlink_and_ignore(mine) }
    @importer.stubs(:include_pending?).returns(false)
    @importer.define_singleton_method(:fetch_paginated_transactions) do |*, **|
      skip_mine.call
      [ { transaction_id: "tx1", booking_date: Date.current.to_s, transaction_amount: { amount: "15.00", currency: "EUR" }, credit_debit_indicator: "DBIT" } ]
    end

    @importer.send(:fetch_and_store_transactions, mine)

    mine.reload
    assert mine.ignored?
    assert_nil mine.raw_transactions_payload
  end

  test "an account unlinked and ignored while its balance is being fetched is not written back" do
    mine = linked_account("hash_mine")
    skip_mine = -> { unlink_and_ignore(mine) }
    provider = Object.new
    provider.define_singleton_method(:get_account_balances) do |**|
      skip_mine.call
      { balances: [ { balance_type: "ITBD", balance_amount: { amount: "50.00", currency: "EUR" }, credit_debit_indicator: "CRDT" } ] }
    end
    importer = EnableBankingItem::Importer.new(@item, enable_banking_provider: provider)

    importer.send(:fetch_and_update_balance, mine)

    mine.reload
    assert mine.ignored?
    assert_nil mine.current_balance
  end

  private

    def linked_account(uid)
      enable_banking_account = @item.enable_banking_accounts.create!(name: "Mine", uid: uid, account_id: "uid-mine", currency: "EUR", current_balance: 10)
      account = Account.create!(family: @item.family, name: "Mine", balance: 10, currency: "EUR", accountable: Depository.new)
      AccountProvider.create!(account: account, provider: enable_banking_account)
      enable_banking_account
    end

    # What another request does while a sync is fetching this account.
    def unlink_and_ignore(enable_banking_account)
      AccountProvider.find_by(provider: enable_banking_account)&.destroy!
      EnableBankingAccount.find(enable_banking_account.id).ignore!
    end
end
