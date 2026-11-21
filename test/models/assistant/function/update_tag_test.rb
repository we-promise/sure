require "test_helper"

class Assistant::Function::UpdateTagTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @tag = tags(:one)
    @fn = Assistant::Function::UpdateTag.new(@user)
  end

  test "requires the stable id returned by get_tags and removes the mutable-name selector" do
    schema = @fn.params_schema

    assert_equal [ "id" ], schema[:required]
    assert schema[:properties].key?(:id)
    refute schema[:properties].key?(:name)
  end

  test "updates tag name and color by id" do
    result = @fn.call("id" => @tag.id, "new_name" => "Updated Name", "color" => "#6471eb")

    assert result[:success]
    assert_equal "Updated Name", @tag.reload.name
    assert_equal "#6471eb", @tag.color
  end

  test "returns structured errors for unknown id no changes and invalid color" do
    assert_equal "not_found", @fn.call("id" => SecureRandom.uuid, "new_name" => "X")[:error]
    assert_equal "not_found", @fn.call("id" => "not-a-uuid", "new_name" => "X")[:error]
    assert_equal "no_changes", @fn.call("id" => @tag.id)[:error]
    assert_equal "validation_failed", @fn.call("id" => @tag.id, "color" => "invalid")[:error]
  end

  test "cannot update a tag from another family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_tag = other_family.tags.create!(name: "Other Tag")

    result = @fn.call("id" => other_tag.id, "new_name" => "Hijacked")

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
  end
end
