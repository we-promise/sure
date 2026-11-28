# frozen_string_literal: true

require "test_helper"

class BrexItem::LifecycleTest < ActiveSupport::TestCase
  include ProviderItemLifecycleTests

  private
    def provider_item
      @provider_item ||= brex_items(:one)
    end

    def other_provider_account
      @other_provider_account ||= mercury_accounts(:checking_account)
    end
end
