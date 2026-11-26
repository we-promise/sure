require "test_helper"

class PurchaseInboxRouteTest < ActiveSupport::TestCase
  test "values are normalized and unique per kind" do
    route = PurchaseInboxRoute.create!(user: users(:family_member), kind: "sender", value: " Me@Example.com ")
    assert_equal "me@example.com", route.value

    duplicate = PurchaseInboxRoute.new(user: users(:family_admin), kind: "sender", value: "ME@example.com")
    refute duplicate.valid?
  end

  test "the same value may exist once per kind" do
    assert PurchaseInboxRoute.new(user: users(:family_member), kind: "tag", value: "me").valid?
    PurchaseInboxRoute.create!(user: users(:family_member), kind: "tag", value: "me")
    assert PurchaseInboxRoute.new(user: users(:family_member), kind: "sender", value: "me@example.com").valid?
  end

  test "tags reject plus signs, spaces and overly long values" do
    refute PurchaseInboxRoute.new(user: users(:family_member), kind: "tag", value: "a+b").valid?
    refute PurchaseInboxRoute.new(user: users(:family_member), kind: "tag", value: "a b").valid?
    refute PurchaseInboxRoute.new(user: users(:family_member), kind: "tag", value: "a" * 33).valid?
    assert PurchaseInboxRoute.new(user: users(:family_member), kind: "tag", value: "marcin.j-1").valid?
  end

  test "sender routes must be email addresses" do
    refute PurchaseInboxRoute.new(user: users(:family_member), kind: "sender", value: "not-an-email").valid?
  end
end
