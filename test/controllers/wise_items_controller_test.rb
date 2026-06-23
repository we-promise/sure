# frozen_string_literal: true

require "test_helper"

class WiseItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)
    @family = families(:dylan_family)
    @wise_item = wise_items(:one)

    @valid_profiles = [
      { "id" => "99999999", "type" => "personal", "details" => { "firstName" => "Jane", "lastName" => "Doe" } }
    ]
  end

  # create renders select_profiles directly — token must NOT appear in the session

  test "create renders select_profiles and keeps token out of session" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)

    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }

    assert_response :success
    assert_nil session[:wise_pending_token], "raw API token must not be stored in the session"
    assert_select "input[name='encrypted_pending_token']"
  end

  test "create stores an encrypted token that round-trips to the original value" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)

    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }

    encrypted = css_select("input[name='encrypted_pending_token']").first["value"]
    assert encrypted.present?, "hidden encrypted_pending_token field must be present"

    key = Rails.application.key_generator.generate_key("wise_pending_token", 32)
    decrypted = ActiveSupport::MessageEncryptor.new(key).decrypt_and_verify(encrypted)
    assert_equal "live_token_abc", decrypted
  end

  test "create re-renders new when token is blank" do
    post wise_items_url, params: { wise_item: { token: "" } }
    assert_response :unprocessable_entity
    assert_nil session[:wise_pending_token]
  end

  test "create re-renders new when Wise API rejects the token" do
    Provider::Wise.any_instance.stubs(:get_profiles).raises(
      Provider::Wise::WiseError.new("unauthorized", :unauthorized)
    )

    post wise_items_url, params: { wise_item: { token: "bad_token" } }
    assert_response :unprocessable_entity
    assert_nil session[:wise_pending_token]
  end

  # link_profiles uses the encrypted hidden field, not the session

  test "link_profiles creates WiseItems using the encrypted token" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)
    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }

    encrypted = css_select("input[name='encrypted_pending_token']").first["value"]

    assert_difference "WiseItem.count", 1 do
      post link_profiles_wise_items_url, params: {
        encrypted_pending_token: encrypted,
        profile_ids: [ "99999999" ]
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal "live_token_abc", @family.wise_items.find_by!(profile_id: "99999999").token
    assert_nil session[:wise_pending_profiles]
  end

  test "link_profiles redirects to new when encrypted token is missing" do
    post link_profiles_wise_items_url, params: {
      encrypted_pending_token: "",
      profile_ids: [ "99999999" ]
    }

    assert_redirected_to new_wise_item_path
  end

  test "link_profiles redirects to new when encrypted token is tampered" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)
    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }

    post link_profiles_wise_items_url, params: {
      encrypted_pending_token: "tampered_garbage_value",
      profile_ids: [ "99999999" ]
    }

    assert_redirected_to new_wise_item_path
  end
end
