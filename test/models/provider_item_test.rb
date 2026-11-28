# frozen_string_literal: true

require "test_helper"

class ProviderItemTest < ActiveSupport::TestCase
  test "the bases are abstract and cannot be instantiated" do
    assert_raises(NotImplementedError) { ProviderItem.new }
    assert_raises(NotImplementedError) { ProviderAccount.new }
  end

  test "a provider keys its connection by its adapter's declaration" do
    assert_equal "brex", BrexItem.provider_key
    assert_equal brex_items(:one).brex_accounts.to_a, brex_items(:one).provider_accounts.to_a

    declared = Provider::BrexAdapter.connection_declaration.merge(key: "brex_declared", accounts: :accounts)
    Provider::Factory.stubs(:connection_declarations).returns([ declared ])

    assert_equal "brex_declared", BrexItem.provider_key
    assert_equal :accounts, brex_items(:one).provider_accounts.proxy_association.reflection.name
  end

  test "a connection without a declaration has no provider key" do
    undeclared = Class.new(ProviderItem) do
      self.table_name = "brex_items"
      def self.name = "UndeclaredItem"
    end

    assert_raises(NotImplementedError) { undeclared.provider_key }
  end

  test "the old Brex constants still resolve to the shared classes" do
    assert_operator BrexItem::Syncer, :<, ProviderItem::Syncer
    assert_same ProviderItem::Syncer::SafeSyncError, BrexItem::Syncer::SafeSyncError
  end
end
