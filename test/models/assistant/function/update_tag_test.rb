require "test_helper"

class Assistant::Function::UpdateTagTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @tag = tags(:one)
    @fn = Assistant::Function::UpdateTag.new(@user)
  end

  test "to_definition returns correct schema" do
    definition = @fn.to_definition
    assert_equal "update_tag", definition[:name]
    assert_not_empty definition[:description]
    assert_includes definition[:params_schema][:required], "name"
  end

  test "params_schema enumerates family tag names" do
    schema = @fn.params_schema
    assert_includes schema[:properties][:name][:enum], @tag.name
  end

  test "updates tag name" do
    result = @fn.call("name" => @tag.name, "new_name" => "Updated Name")

    assert result[:success]
    assert_equal "Updated Name", result[:tag][:name]
    assert_equal "Updated Name", @tag.reload.name
  end

  test "updates tag color" do
    result = @fn.call("name" => @tag.name, "color" => "#6471eb")

    assert result[:success]
    assert_equal "#6471eb", result[:tag][:color]
    assert_equal "#6471eb", @tag.reload.color
  end

  test "updates both name and color at once" do
    result = @fn.call("name" => @tag.name, "new_name" => "Both Updated", "color" => "#db5a54")

    assert result[:success]
    assert_equal "Both Updated", @tag.reload.name
    assert_equal "#db5a54", @tag.reload.color
  end

  test "soft error when tag not found" do
    result = @fn.call("name" => "Nonexistent Tag", "new_name" => "X")

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
  end

  test "soft error when no changes provided" do
    result = @fn.call("name" => @tag.name)

    assert_equal false, result[:success]
    assert_equal "no_changes", result[:error]
  end

  test "soft error when lookup name is empty string" do
    result = @fn.call("name" => "", "new_name" => "X")

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
  end

  test "empty string new_name is treated as absent, returns no_changes" do
    result = @fn.call("name" => @tag.name, "new_name" => "")

    assert_equal false, result[:success]
    assert_equal "no_changes", result[:error]
  end

  test "soft error when color format is invalid" do
    result = @fn.call("name" => @tag.name, "color" => "not-a-color")

    assert_equal false, result[:success]
    assert_equal "validation_failed", result[:error]
  end

  test "cannot update a tag from another family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_tag = other_family.tags.create!(name: "Other Tag")

    result = @fn.call("name" => other_tag.name, "new_name" => "Hijacked")

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
  end
end
