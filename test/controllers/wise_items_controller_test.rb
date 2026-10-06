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

  # Redirecting back to Bank sync would collapse the open connection row.
  test "sync from the panel re-renders the panel in place" do
    post sync_wise_item_url(@wise_item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "wise-providers-panel"
    assert_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert @wise_item.reload.syncing?
  end

  # The Accounts page's Sync button posts here too, without the panel's source.
  test "sync from the Accounts page goes back to it" do
    post sync_wise_item_url(@wise_item),
         headers: { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml", "Referer" => accounts_url }

    assert_redirected_to accounts_url
  end

  # create redirects to select_profiles (Turbo requires a redirect from a standard
  # form submission) — the encrypted token travels via the session, not the response body.

  test "create redirects to select_profiles and keeps raw token out of the session" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)

    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }

    assert_redirected_to select_profiles_wise_items_path
    assert_nil session[:wise_pending_token], "raw API token must not be stored in the session"
    assert session[:wise_pending_encrypted_token].present?

    follow_redirect!
    assert_select "input[name='encrypted_pending_token']"
  end

  test "create stores an encrypted token that round-trips to the original value" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)

    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }
    follow_redirect!

    encrypted = css_select("input[name='encrypted_pending_token']").first["value"]
    assert encrypted.present?, "hidden encrypted_pending_token field must be present"

    key = Rails.application.key_generator.generate_key("wise_pending_token", 32)
    decrypted = ActiveSupport::MessageEncryptor.new(key).decrypt_and_verify(encrypted)
    assert_equal "live_token_abc", decrypted
  end

  test "create redirects to providers on blank token" do
    post wise_items_url, params: { wise_item: { token: "" } }
    assert_redirected_to settings_providers_path
    assert_nil session[:wise_pending_token]
  end

  test "create from the drawer shows a blank token error in the panel" do
    post wise_items_url,
         params: { wise_item: { token: "" } },
         as: :turbo_stream

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "wise-providers-panel"
    assert_includes response.body, ERB::Util.html_escape("Token can't be blank")
  end

  test "create redirects to providers when Wise API rejects the token" do
    Provider::Wise.any_instance.stubs(:get_profiles).raises(
      Provider::Wise::WiseError.new("unauthorized", :unauthorized)
    )

    post wise_items_url, params: { wise_item: { token: "bad_token" } }
    assert_redirected_to settings_providers_path
    assert_nil session[:wise_pending_token]
  end

  # link_profiles reads the encrypted token from the session (set by create) —
  # the client no longer needs to (and cannot) supply or tamper with it via params.

  test "link_profiles creates WiseItems using the session-held encrypted token" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)
    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }

    assert_difference "WiseItem.count", 1 do
      post link_profiles_wise_items_url, params: { profile_ids: [ "99999999" ] }
    end

    assert_redirected_to settings_providers_path
    assert_equal "live_token_abc", @family.wise_items.find_by!(profile_id: "99999999").token
    assert_nil session[:wise_pending_profiles]
    assert_nil session[:wise_pending_encrypted_token]
  end

  test "link_profiles applies the pending import_all_history setting to created items" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)
    post wise_items_url, params: { wise_item: { token: "live_token_abc", import_all_history: "1" } }

    assert_difference "WiseItem.count", 1 do
      post link_profiles_wise_items_url, params: { profile_ids: [ "99999999" ] }
    end

    assert @family.wise_items.find_by!(profile_id: "99999999").import_all_history?
    assert_nil session[:wise_pending_import_all_history]
  end

  test "link_profiles defaults import_all_history to false when not requested" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)
    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }

    post link_profiles_wise_items_url, params: { profile_ids: [ "99999999" ] }

    assert_not @family.wise_items.find_by!(profile_id: "99999999").import_all_history?
  end

  test "link_profiles applies import_all_history to every created profile" do
    profiles = [
      { "id" => "99999999", "type" => "personal", "details" => { "firstName" => "Jane", "lastName" => "Doe" } },
      { "id" => "88888888", "type" => "business", "details" => { "name" => "Acme" } }
    ]
    Provider::Wise.any_instance.stubs(:get_profiles).returns(profiles)
    post wise_items_url, params: { wise_item: { token: "live_token_abc", import_all_history: "1" } }

    assert_difference "WiseItem.count", 2 do
      post link_profiles_wise_items_url, params: { profile_ids: [ "99999999", "88888888" ] }
    end

    assert @family.wise_items.find_by!(profile_id: "99999999").import_all_history?
    assert @family.wise_items.find_by!(profile_id: "88888888").import_all_history?
    assert_nil session[:wise_pending_import_all_history]
  end

  test "link_profiles redirects to providers when there is no pending session" do
    post link_profiles_wise_items_url, params: { profile_ids: [ "99999999" ] }

    assert_redirected_to settings_providers_path
  end

  test "generate_sca_keypair stores a keypair on the item" do
    WiseItem.any_instance.stubs(:sca_encryption_available?).returns(true)

    assert_nil @wise_item.sca_private_key

    post generate_sca_keypair_wise_item_url(@wise_item)

    assert_redirected_to accounts_path
    assert @wise_item.reload.sca_configured?
  end

  test "generate_sca_keypair from the page shows the new public key in place" do
    WiseItem.any_instance.stubs(:sca_encryption_available?).returns(true)

    post generate_sca_keypair_wise_item_url(@wise_item),
         as: :turbo_stream

    assert_turbo_stream action: "replace", target: "wise-providers-panel"
    assert_includes response.body, %(id="wise-providers-panel")
    assert_includes response.body, @wise_item.reload.sca_public_key.lines.second.strip
  end

  test "update from the page re-renders the panel in place instead of leaving for accounts" do
    patch wise_item_url(@wise_item),
          params: { wise_item: { name: "Renamed Wise" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "wise-providers-panel"
    assert_equal "Renamed Wise", @wise_item.reload.name
  end

  test "generate_sca_keypair replaces a previously generated keypair" do
    WiseItem.any_instance.stubs(:sca_encryption_available?).returns(true)

    @wise_item.generate_sca_keypair!
    previous_key = @wise_item.sca_private_key

    post generate_sca_keypair_wise_item_url(@wise_item)

    assert_not_equal previous_key, @wise_item.reload.sca_private_key
  end

  test "generate_sca_keypair reports an error rather than storing a key in the clear" do
    WiseItem.stubs(:encryption_ready?).returns(false)

    post generate_sca_keypair_wise_item_url(@wise_item)

    assert_nil @wise_item.reload.sca_private_key
  end

  test "link_profiles redirects to providers when the session token cannot be decrypted" do
    Provider::Wise.any_instance.stubs(:get_profiles).returns(@valid_profiles)
    post wise_items_url, params: { wise_item: { token: "live_token_abc" } }

    session[:wise_pending_encrypted_token] = "corrupted_garbage_value"

    post link_profiles_wise_items_url, params: { profile_ids: [ "99999999" ] }

    assert_redirected_to settings_providers_path
  end
end
