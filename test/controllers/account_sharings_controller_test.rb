require "test_helper"

class AccountSharingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @account = accounts(:depository)

    FamilyMembership.create!(user: @admin, family: @admin.family)
    FamilyMembership.create!(user: @member, family: @admin.family)
  end

  test "show lists current family members eligible for sharing" do
    sign_in @admin

    get account_sharing_path(@account)

    assert_response :success
    assert_includes response.body, @member.display_name
  end

  test "show does not list members from other families" do
    sign_in @admin

    other_user = users(:empty)

    get account_sharing_path(@account)

    assert_response :success
    assert_no_match other_user.display_name, response.body
  end
end
