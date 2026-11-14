# frozen_string_literal: true

require "test_helper"

class ProviderItemTest < ActiveSupport::TestCase
  test "the bases are abstract and cannot be instantiated" do
    assert_raises(NotImplementedError) { ProviderItem.new }
    assert_raises(NotImplementedError) { ProviderAccount.new }
  end

  test "a provider keys its connection by its own model name" do
    assert_equal "brex", BrexItem.provider_key
    assert_equal brex_items(:one).brex_accounts.to_a, brex_items(:one).provider_accounts.to_a
  end

  test "the old Brex constants still resolve to the shared classes" do
    assert_operator BrexItem::Syncer, :<, ProviderItem::Syncer
    assert_same ProviderItem::Syncer::SafeSyncError, BrexItem::Syncer::SafeSyncError
  end
end
