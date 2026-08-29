require "test_helper"

class Admin::FamiliesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:sure_support_staff)
  end

  test "destroy deletes an unused family" do
    family = Family.create!(name: "Unused Family")

    assert_difference("Family.count", -1) do
      delete admin_family_url(family)
    end

    assert_redirected_to admin_users_url
  end

  test "destroy does not delete a family with users" do
    family = users(:family_admin).family

    assert_no_difference("Family.count") do
      delete admin_family_url(family)
    end

    assert_redirected_to admin_users_url
  end

  test "destroy does not delete a family with an active subscription" do
    family = Family.create!(name: "Subscribed Empty Family")
    family.start_subscription!("sub_admin_cleanup")

    assert_no_difference("Family.count") do
      delete admin_family_url(family)
    end

    assert_redirected_to admin_users_url
    assert_equal "Could not cancel active Stripe subscription. Please cancel it manually before deleting the family.", flash[:alert]
  end
end
