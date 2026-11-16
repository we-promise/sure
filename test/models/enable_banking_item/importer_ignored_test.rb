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
end
