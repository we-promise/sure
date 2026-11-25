require "test_helper"

class Provider::TinkoffInvestAdapterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = @family.tinkoff_invest_items.create!(name: "T-Invest", api_key: "test-token")
    @tinkoff_account = @item.tinkoff_invest_accounts.create!(
      name: "Brokerage",
      tinkoff_invest_account_id: "acct-1",
      currency: "RUB"
    )
  end

  test "registers with Provider::Factory for TinkoffInvestAccount" do
    adapter = Provider::Factory.create_adapter(@tinkoff_account)

    assert_instance_of Provider::TinkoffInvestAdapter, adapter
    assert_equal "tinkoff_invest", adapter.provider_name
    assert_equal @item, adapter.item
    assert_not adapter.can_delete_holdings?
    assert_equal "tbank.ru", adapter.institution_domain
  end

  test "supports Investment accounts and exposes connection configs" do
    assert_equal %w[Investment], Provider::TinkoffInvestAdapter.supported_account_types

    configs = Provider::TinkoffInvestAdapter.connection_configs(family: @family)
    assert_equal 1, configs.size
    assert_equal "tinkoff_invest", configs.first[:key]
    assert configs.first[:can_connect]
  end
end
