require "test_helper"

class IbkrItemImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @ibkr_item = @family.ibkr_items.create!(
      name: "Interactive Brokers",
      query_id: "QUERY123",
      token: "TOKEN123"
    )
  end

  test "imports accounts from parsed flex statement" do
    provider = mock("ibkr_provider")
    provider.expects(:download_statement).returns(file_fixture("ibkr/flex_statement.xml").read)

    assert_difference "IbkrAccount.count", 2 do
      result = IbkrItem::Importer.new(@ibkr_item, ibkr_provider: provider).import
      assert_equal true, result[:success]
      assert_equal 2, result[:accounts_imported]
    end

    primary_account = @ibkr_item.ibkr_accounts.find_by!(ibkr_account_id: "U1234567")
    assert_equal "CHF", primary_account.currency
    assert_equal BigDecimal("3351.0"), primary_account.current_balance
    assert_equal 2, primary_account.raw_equity_summary_payload.size
    assert_equal 1, primary_account.raw_holdings_payload.size
    assert_equal 2, primary_account.raw_activities_payload["trades"].size
    assert_equal 2, primary_account.raw_activities_payload["cash_transactions"].size
  end
end
