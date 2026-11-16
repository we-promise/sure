# frozen_string_literal: true

require "test_helper"

class MercuryItem::LifecycleTest < ActiveSupport::TestCase
  include ProviderItemLifecycleTests

  private
    def provider_item
      @provider_item ||= mercury_items(:one)
    end

    def other_provider_account
      @other_provider_account ||= lunchflow_accounts(:investment_account)
    end

    def selectable_accountable_type
      "Depository"
    end

    def provider_api_error
      @provider_api_error ||= Provider::Mercury::MercuryError.new("Mercury is unavailable", :server_error)
    end

    def api_accounts_for(account_ids)
      account_ids.map { |id| { id: id, name: "Mercury #{id}" } }
    end
end
