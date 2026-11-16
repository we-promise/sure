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

  test "a sync leaves an ignored account untouched" do
    @importer.stubs(:fetch_session_data).returns(
      accounts: [ { uid: "uid-new", identification_hash: "hash_theirs", currency: "EUR", name: "Renamed" } ]
    )

    assert_no_changes -> { @ignored.reload.attributes } do
      @importer.import
    end
  end
end
