require "test_helper"

class Import::AccountTypeMappingTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @import = imports(:account)
    Current.session = @user.sessions.create!
  end

  test "preview account types are offered only to users who opted in" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    mapping = @import.mappings.new(key: "gift", type: "Import::AccountTypeMapping")

    assert_not_includes mapping.selectable_values.map(&:last), "GiftCard"

    mapping.value = "GiftCard"
    assert_not mapping.valid?

    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))

    assert_includes mapping.selectable_values.map(&:last), "GiftCard"
    assert mapping.valid?
  end
end
