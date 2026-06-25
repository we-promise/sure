require "test_helper"

class Assistant::Function::GetTagsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetTags.new(@user)
  end

  test "to_definition returns correct name and description" do
    definition = @fn.to_definition
    assert_equal "get_tags", definition[:name]
    assert_not_empty definition[:description]
    assert_equal "object", definition[:params_schema][:type]
  end

  test "returns all family tags sorted alphabetically" do
    result = @fn.call

    assert_kind_of Array, result[:tags]
    assert_equal @family.tags.count, result[:total]

    names = result[:tags].map { |t| t[:name] }
    assert_equal names.sort, names
  end

  test "each tag includes id, name, and color" do
    result = @fn.call
    result[:tags].each do |t|
      assert t[:id].present?
      assert t[:name].present?
      assert t[:color].present?
    end
  end

  test "scopes to the user's family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_family.tags.create!(name: "Foreign Tag")

    result = @fn.call
    tag_names = result[:tags].map { |t| t[:name] }
    assert_not_includes tag_names, "Foreign Tag"
  end
end
