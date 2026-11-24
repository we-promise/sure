require "test_helper"

class TinkoffInvestItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "requires api_key on create and validates base_url format" do
    missing_key = @family.tinkoff_invest_items.build(name: "T-Invest")
    assert_not missing_key.valid?
    assert_includes missing_key.errors[:api_key], "can't be blank"

    bad_url = @family.tinkoff_invest_items.build(name: "T-Invest", api_key: "tok", base_url: "ftp://invalid")
    assert_not bad_url.valid?
    assert_predicate bad_url.errors[:base_url], :present?
  end

  test "resolves effective_base_url for live, sandbox, and custom endpoint" do
    live = @family.tinkoff_invest_items.create!(name: "Live", api_key: "tok", environment: :live)
    sandbox = @family.tinkoff_invest_items.create!(name: "Sandbox", api_key: "tok", environment: :sandbox)
    custom = @family.tinkoff_invest_items.create!(name: "Custom", api_key: "tok", environment: :live, base_url: "https://tinvest.example.test/rest")

    assert_equal Provider::TinkoffInvest::PortfolioClient::LIVE_BASE_URL, live.effective_base_url
    assert_equal Provider::TinkoffInvest::PortfolioClient::SANDBOX_BASE_URL, sandbox.effective_base_url
    assert_equal "https://tinvest.example.test/rest", custom.effective_base_url
  end

  test "encrypts api_key when Active Record encryption is configured" do
    item = @family.tinkoff_invest_items.create!(name: "T-Invest", api_key: "plain-secret-token")

    if TinkoffInvestItem.encryption_ready?
      assert item.encrypted_attribute?(:api_key)
      raw_value = TinkoffInvestItem.connection.select_value(
        TinkoffInvestItem.sanitize_sql_array([ "SELECT api_key FROM tinkoff_invest_items WHERE id = ?", item.id ])
      )
      assert_not_equal "plain-secret-token", raw_value
      assert_equal "plain-secret-token", item.reload.api_key
    else
      assert_equal "plain-secret-token", item.reload.api_key
    end
  end

  test "import_latest_data raises PortfolioClient::ConfigurationError when token is blank" do
    item = @family.tinkoff_invest_items.create!(name: "T-Invest", api_key: "tok")
    item.api_key = ""

    assert_raises(Provider::TinkoffInvest::PortfolioClient::ConfigurationError) do
      item.import_latest_data
    end
  end

  test "unlink_all! removes AccountProvider links and nulls holding ownership while retaining accounts" do
    item = @family.tinkoff_invest_items.create!(name: "T-Invest", api_key: "tok")
    tinkoff_account = item.tinkoff_invest_accounts.create!(name: "Brokerage", tinkoff_invest_account_id: "acct-1", currency: "RUB")
    account = @family.accounts.create!(name: "Brokerage", balance: 0, currency: "RUB", accountable: Investment.new)
    link = tinkoff_account.ensure_account_provider!(account)
    security = Security.find_or_create_by!(ticker: "SBER", exchange_operating_mic: "MISX")
    holding = account.holdings.create!(security: security, date: Date.current, qty: 10, price: 300, amount: 3000, currency: "RUB", account_provider: link)

    results = item.unlink_all!

    assert_equal 1, results.size
    assert_nil tinkoff_account.reload.account_provider
    assert_nil holding.reload.account_provider_id
    assert Account.exists?(account.id)
  end
end
