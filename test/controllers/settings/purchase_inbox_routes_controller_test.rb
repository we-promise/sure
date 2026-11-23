require "test_helper"

class Settings::PurchaseInboxRoutesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @admin.update!(role: :super_admin, preferences: @admin.preferences.merge("preview_features_enabled" => true))
    sign_in @admin
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ApplicationController.any_instance.stubs(:redis_connected?).returns(true)
  end

  test "adds a sender address for a user" do
    assert_difference -> { users(:family_member).purchase_inbox_routes.sender.count }, 1 do
      post settings_purchase_inbox_routes_url, params: { purchase_inbox_route: { user_id: users(:family_member).id, kind: "sender", value: "Member@Example.com" } }
    end

    assert_redirected_to settings_purchase_inbox_url
    assert_equal "member@example.com", users(:family_member).purchase_inbox_routes.sender.last.value
  end

  test "a blank tag gets an unguessable default" do
    post settings_purchase_inbox_routes_url, params: { purchase_inbox_route: { user_id: users(:family_member).id, kind: "tag", value: "" } }

    tag = users(:family_member).purchase_inbox_routes.tag.last.value
    assert_match(/\A[a-z0-9]+-[a-z0-9]{8}\z/, tag)
  end

  test "an invalid value is reported" do
    post settings_purchase_inbox_routes_url, params: { purchase_inbox_route: { user_id: users(:family_member).id, kind: "sender", value: "nope" } }

    assert_redirected_to settings_purchase_inbox_url
    assert flash[:alert].present?
  end

  test "removes a route" do
    route = purchase_inbox_routes(:admin_sender)

    delete settings_purchase_inbox_route_url(route)

    assert_not PurchaseInboxRoute.exists?(route.id)
  end

  test "a family admin can only add routes for their own family" do
    @admin.update!(role: :admin)
    User.any_instance.stubs(:manages_instance_settings?).returns(true)
    outsider = users(:empty)

    post settings_purchase_inbox_routes_url, params: { purchase_inbox_route: { user_id: outsider.id, kind: "sender", value: "x@example.com" } }

    assert_response :not_found
  end

  test "someone who can't change instance settings can't add routes" do
    @admin.update!(role: :admin)
    User.any_instance.stubs(:manages_instance_settings?).returns(false)

    assert_no_difference -> { PurchaseInboxRoute.count } do
      post settings_purchase_inbox_routes_url, params: { purchase_inbox_route: { user_id: @admin.id, kind: "sender", value: "x@example.com" } }
    end
  end
end
