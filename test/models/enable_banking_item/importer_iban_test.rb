require "test_helper"

class EnableBankingItem::ImporterIbanTest < ActiveSupport::TestCase
  setup do
    @item = EnableBankingItem.create!(
      family: families(:dylan_family),
      name: "Test EB",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now
    )
    # Linked before accounts had an IBAN: the provider account knows it, the account doesn't.
    @eb_account = @item.enable_banking_accounts.create!(
      name: "Giro", uid: "hash_giro", account_id: "uid-giro", currency: "EUR",
      iban: "DE89370400440532013000" # pipelock:ignore IBAN
    )
    @account = Account.create!(family: @item.family, name: "Giro", balance: 0, currency: "EUR", accountable: Depository.new)
    AccountProvider.create!(account: @account, provider: @eb_account)
  end

  test "a sync fills the IBAN of an account linked before it had one" do
    importer_with_session(accounts: [ "uid-giro" ]).import

    assert_equal "DE89370400440532013000", @account.reload.iban # pipelock:ignore IBAN
  end

  test "a sync keeps an IBAN the user cleared on purpose" do
    @account.update!(iban: nil)
    @account.lock_attr!(:iban)

    importer_with_session(accounts: [ "uid-giro" ]).import

    assert_nil @account.reload.iban
  end

  test "a sync keeps an IBAN the user entered" do
    @account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN

    importer_with_session(accounts: [ "uid-giro" ]).import

    assert_equal "AT611904300234573201", @account.reload.iban # pipelock:ignore IBAN
  end

  private
    def importer_with_session(session)
      provider = stub("enable_banking_provider", get_account_transactions: { transactions: [] }, get_account_balances: { balances: [] })
      importer = EnableBankingItem::Importer.new(@item.reload, enable_banking_provider: provider)
      importer.stubs(:fetch_session_data).returns(session)
      importer
    end
end
