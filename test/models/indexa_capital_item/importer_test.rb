# frozen_string_literal: true

require "test_helper"

class IndexaCapitalItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @item = indexa_capital_items(:configured_with_token)
    @ignored = indexa_capital_accounts(:pension_plan)
    @ignored.ignore!
    @provider = mock("indexa_capital_provider")
    @provider.stubs(:list_accounts).returns([
      { account_number: "LPYH3MCQ", name: "Mutual Fund", type: "mutual", status: "active", currency: "EUR" },
      { account_number: "DCU8HWEP", name: "Someone else's pension", type: "pension", status: "active", currency: "EUR" }
    ])
  end

  test "an ignored account is neither fetched nor updated, and survives the sync" do
    @provider.expects(:get_account_balance).with(account_number: "LPYH3MCQ").returns(100)
    @provider.expects(:get_account_balance).with(account_number: "DCU8HWEP").never

    assert_no_changes -> { @ignored.reload.attributes } do
      IndexaCapitalItem::Importer.new(@item, indexa_capital_provider: @provider).import
    end

    assert @ignored.reload.ignored?
    assert_equal 100, indexa_capital_accounts(:mutual_fund).reload.current_balance
  end
end
