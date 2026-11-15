# frozen_string_literal: true

require "test_helper"

class BrexItem::LifecycleTest < ActiveSupport::TestCase
  include ProviderItemLifecycleTests

  test "Brex offers cash accounts as depository and cards as credit cards" do
    BrexItem::AccountFlow.any_instance.stubs(:fetch_accounts).returns([
      { id: "cash-1", name: "Brex Cash", account_kind: "cash" },
      { id: "card-1", name: "Brex Card", account_kind: "card" }
    ])
    offered = ->(type) { BrexItem::AccountFlow.new(family: provider_item.family, brex_item: provider_item).select_accounts_result(accountable_type: type).available_accounts.map { |account| account[:id] } }

    with_memory_cache do
      assert_equal [ "cash-1" ], offered.call("Depository")
      assert_equal [ "card-1" ], offered.call("CreditCard")
    end
  end

  private
    def provider_item
      @provider_item ||= brex_items(:one)
    end

    def other_provider_account
      @other_provider_account ||= mercury_accounts(:checking_account)
    end

    def selectable_accountable_type
      "Depository"
    end

    def api_accounts_for(account_ids)
      account_ids.map { |id| { id: id, name: "Brex #{id}", account_kind: "cash" } }
    end
end
