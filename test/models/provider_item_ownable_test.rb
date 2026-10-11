require "test_helper"

class ProviderItemOwnableTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin  = users(:family_admin)
    @member = users(:family_member)
    Current.reset
  end

  teardown { Current.reset }

  # An anonymous model that includes the concern without declaring a scope,
  # standing in for any of the 24 providers that have not been classified yet.
  def undeclared_item_class
    Class.new(ApplicationRecord) do
      self.table_name = "plaid_items"
      belongs_to :family
      include ProviderItemOwnable

      def self.name = "UndeclaredItem"
    end
  end

  test "credential scope defaults to tenant_wide so an unclassified provider stays admin-only" do
    klass = undeclared_item_class

    assert_equal :tenant_wide, klass.declared_credential_scope
    assert_not klass.member_connectable?
  end

  test "credential scope rejects an unknown value" do
    error = assert_raises(ArgumentError) { undeclared_item_class.credential_scope(:sometimes) }
    assert_match(/unknown credential scope/, error.message)
  end

  test "PlaidItem declares per_connection" do
    assert_equal :per_connection, PlaidItem.declared_credential_scope
    assert PlaidItem.member_connectable?
  end

  test "owner defaults to the current user" do
    Current.session = @member.sessions.create!

    item = @family.plaid_items.create!(
      name: "Member Bank", plaid_id: "item_owner_default", access_token: "token_owner_default"
    )

    assert_equal @member, item.owner
  end

  test "owner falls back to a family admin when there is no current user" do
    item = @family.plaid_items.create!(
      name: "Console Bank", plaid_id: "item_owner_fallback", access_token: "token_owner_fallback"
    )

    assert_equal @admin, item.owner
  end

  test "owner must belong to the same family" do
    outsider = users(:empty)

    item = @family.plaid_items.new(
      name: "Cross Family", plaid_id: "item_cross", access_token: "token_cross", owner: outsider
    )

    assert_not item.valid?
    assert_includes item.errors[:owner], "is invalid"
  end

  test "an admin may manage any connection in the family" do
    item = plaid_items(:one)
    item.update!(owner: @member)

    assert item.manageable_by?(@admin)
  end

  test "a member may manage a per_connection item they own" do
    item = plaid_items(:one)
    item.update!(owner: @member)

    assert item.manageable_by?(@member)
  end

  test "a member may not manage a connection owned by someone else" do
    item = plaid_items(:one)
    item.update!(owner: @admin)

    assert_not item.manageable_by?(@member)
  end

  test "manageable_by? is false without a user" do
    assert_not plaid_items(:one).manageable_by?(nil)
  end
end
