# frozen_string_literal: true

require "test_helper"

class MercuryItem::LifecycleTest < ActiveSupport::TestCase
  include ProviderItemModelLifecycleTests

  private
    def provider_item
      @provider_item ||= mercury_items(:one)
    end

    def other_provider_account
      @other_provider_account ||= lunchflow_accounts(:investment_account)
    end
end
