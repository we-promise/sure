require "test_helper"

class Provider::MemberConnectableTest < ActiveSupport::TestCase
  test "Plaid is member connectable" do
    assert Provider::PlaidAdapter.member_connectable?
    assert_equal PlaidItem, Provider::PlaidAdapter.connection_item_class
  end

  test "SimpleFIN is not member connectable" do
    # One access_url reads every account on the bridge, so it is tenant-wide
    # and stays admin-only.
    assert_not Provider::SimplefinAdapter.member_connectable?
  end

  test "an adapter that declares no item class is not member connectable" do
    # The fail-closed default: every provider that has not been classified
    # behaves exactly as it does today.
    assert_nil Provider::Base.connection_item_class
    assert_not Provider::Base.member_connectable?
  end

  test "no adapter is member connectable without declaring per_connection" do
    Provider::Factory.registered_adapters.each do |adapter|
      next unless adapter.member_connectable?

      item_class = adapter.connection_item_class
      assert_equal :per_connection, item_class.declared_credential_scope,
        "#{adapter.name} is member-connectable but #{item_class} does not declare per_connection"
    end
  end

  test "plaid connection configs carry the member_connectable flag" do
    family = families(:dylan_family)
    family.stubs(:can_connect_plaid_us?).returns(true)
    family.stubs(:can_connect_plaid_eu?).returns(false)

    configs = Provider::PlaidAdapter.connection_configs(family: family)

    assert configs.any?, "expected at least one Plaid connection config"
    assert configs.all? { |config| config[:member_connectable] }
  end
end
