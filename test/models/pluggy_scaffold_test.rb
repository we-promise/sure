# frozen_string_literal: true

require "test_helper"

class PluggyScaffoldTest < ActiveSupport::TestCase
  test "PluggyItem defines SyncCompleteEvent so sync does not NameError" do
    assert PluggyItem.const_defined?(:SyncCompleteEvent, false)
  end

  test "PENDING_PROVIDERS includes pluggy" do
    assert_includes Transaction::PENDING_PROVIDERS, "pluggy"
  end

  test "pluggy config defaults are present" do
    assert_equal "https://api.pluggy.ai", Rails.configuration.x.pluggy.base_url
    assert Rails.configuration.x.pluggy.include_pending
  end

  test "family exposes pluggy connectable" do
    assert families(:dylan_family).respond_to?(:pluggy_items)
  end
end
