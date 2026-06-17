require "test_helper"

class Assistant::Function::CreateTagTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::CreateTag.new(@user)
  end

  test "to_definition returns correct schema" do
    definition = @fn.to_definition
    assert_equal "create_tag", definition[:name]
    assert_not_empty definition[:description]
    assert_includes definition[:params_schema][:required], "name"
  end

  test "creates a tag with name and color" do
    assert_difference "@family.tags.count" do
      result = @fn.call("name" => "Vacation", "color" => "#4da568")

      assert result[:success]
      assert_equal "Vacation", result[:tag][:name]
      assert_equal "#4da568", result[:tag][:color]
      assert result[:tag][:id].present?
    end
  end

  test "auto-assigns a color from palette when omitted" do
    result = @fn.call("name" => "Auto Color")

    assert result[:success]
    assert_includes Tag::COLORS, result[:tag][:color]
  end

  test "soft error when name is blank" do
    result = @fn.call("name" => "")

    assert_equal false, result[:success]
    assert_equal "name_required", result[:error]
  end

  test "soft error on duplicate name within family" do
    existing = tags(:one)
    result = @fn.call("name" => existing.name)

    assert_equal false, result[:success]
    assert_equal "validation_failed", result[:error]
  end

  test "soft error when name is whitespace only" do
    result = @fn.call("name" => "   ")

    assert_equal false, result[:success]
    assert_equal "name_required", result[:error]
  end

  test "soft error when color format is invalid" do
    result = @fn.call("name" => "Bad Color", "color" => "not-a-color")

    assert_equal false, result[:success]
    assert_equal "validation_failed", result[:error]
  end

  test "scopes created tag to user's family" do
    @fn.call("name" => "Scoped Tag")
    tag = @family.tags.find_by(name: "Scoped Tag")
    assert tag.present?
    assert_equal @family.id, tag.family_id
  end
end
