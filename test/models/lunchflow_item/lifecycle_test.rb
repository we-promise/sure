# frozen_string_literal: true

require "test_helper"

class LunchflowItem::LifecycleTest < ActiveSupport::TestCase
  include ProviderItemLifecycleTests

  test "a sync warns about limited data only when a linked account is an investment or crypto account" do
    provider_item.class.any_instance.stubs(:import_latest_lunchflow_data).returns(success: true)
    provider_item.class.any_instance.stubs(:process_accounts).returns([])
    provider_item.class.any_instance.stubs(:schedule_account_syncs).returns([])
    account, _link = link_provider_account(provider_account)
    warning = I18n.t("provider_warnings.limited_investment_data")

    account.update!(accountable: Depository.new)
    depository_details = Sync.create!(syncable: provider_item).tap(&:perform).reload.sync_stats["data_quality_details"]

    account.update!(accountable: Investment.new)
    investment_details = Sync.create!(syncable: provider_item).tap(&:perform).reload.sync_stats["data_quality_details"]

    account.update!(accountable: Crypto.new)
    crypto_details = Sync.create!(syncable: provider_item).tap(&:perform).reload.sync_stats["data_quality_details"]

    assert_not_includes Array(depository_details).map { |detail| detail["message"] }, warning
    assert_includes Array(investment_details).map { |detail| detail["message"] }, warning
    assert_includes Array(crypto_details).map { |detail| detail["message"] }, warning
  end

  test "the limited-data warning counts each linked investment or crypto account" do
    provider_item.class.any_instance.stubs(:import_latest_lunchflow_data).returns(success: true)
    provider_item.class.any_instance.stubs(:process_accounts).returns([])
    provider_item.class.any_instance.stubs(:schedule_account_syncs).returns([])
    { "lf_count_investment" => Investment, "lf_count_crypto" => Crypto, "lf_count_depository" => Depository }.each do |account_id, type|
      record = provider_item.lunchflow_accounts.create!(account_id: account_id, name: account_id, currency: "USD")
      account, _link = link_provider_account(record)
      account.update!(accountable: type.new)
    end
    provider_item.lunchflow_accounts.where.not(account_id: %w[lf_count_investment lf_count_crypto lf_count_depository]).destroy_all

    stats = Sync.create!(syncable: provider_item).tap(&:perform).reload.sync_stats

    assert_equal 2, stats["data_warnings"]
  end

  private
    def provider_item
      @provider_item ||= lunchflow_items(:one)
    end

    def other_provider_account
      @other_provider_account ||= mercury_accounts(:checking_account)
    end

    def selectable_accountable_type
      "Depository"
    end

    def provider_api_error
      @provider_api_error ||= Provider::Lunchflow::LunchflowError.new("Lunch Flow is unavailable", :server_error)
    end

    def api_accounts_for(account_ids)
      account_ids.map { |id| { id: id, name: "Lunch Flow #{id}", currency: "USD" } }
    end
end
