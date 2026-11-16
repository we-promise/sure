# frozen_string_literal: true

require "test_helper"

class LunchflowItem::LifecycleTest < ActiveSupport::TestCase
  include ProviderItemModelLifecycleTests

  test "a sync warns about limited data only when a linked account is an investment account" do
    provider_item.class.any_instance.stubs(:import_latest_lunchflow_data).returns(success: true)
    provider_item.class.any_instance.stubs(:process_accounts).returns([])
    provider_item.class.any_instance.stubs(:schedule_account_syncs).returns([])
    account, _link = link_provider_account(provider_account)
    warning = I18n.t("provider_warnings.limited_investment_data")

    account.update!(accountable: Depository.new)
    depository_details = Sync.create!(syncable: provider_item).tap(&:perform).reload.sync_stats["data_quality_details"]

    account.update!(accountable: Investment.new)
    investment_details = Sync.create!(syncable: provider_item).tap(&:perform).reload.sync_stats["data_quality_details"]

    assert_not_includes Array(depository_details).map { |detail| detail["message"] }, warning
    assert_includes Array(investment_details).map { |detail| detail["message"] }, warning
  end

  private
    def provider_item
      @provider_item ||= lunchflow_items(:one)
    end

    def other_provider_account
      @other_provider_account ||= mercury_accounts(:checking_account)
    end
end
