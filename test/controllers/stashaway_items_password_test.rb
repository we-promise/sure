require "test_helper"

# Keeping the StashAway password. In its own file: CI reruns every test file
# that mentions encryption_ready? with encryption keys, and the controller's
# other tests render pages whose fixtures are not made for that.
class StashawayItemsPasswordTest < ActionDispatch::IntegrationTest
  PANEL = { "Turbo-Frame" => "stashaway-connect-form" }.freeze

  setup do
    sign_in users(:family_admin)
    @item = stashaway_items(:connected)
  end

  test "keeps the password when asked and encryption is configured" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    stub_login

    post stashaway_items_url, params: { stashaway_login: { email: "new@example.com", password: "secret", remember_password: "1" } }, headers: PANEL

    assert_response :success
    item = StashawayItem.order(:created_at).last
    assert_equal "secret", item.password
    assert_select "turbo-stream[target=stashaway-providers-panel] template p", text: "Password saved; Sure signs in again by itself."
    assert_select "turbo-stream[target=stashaway-providers-panel] template form[action=?]", forget_password_stashaway_item_path(item)
  end

  test "does not keep the password unless asked" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    stub_login

    post stashaway_items_url, params: { stashaway_login: { email: "new@example.com", password: "secret", remember_password: "0" } }, headers: PANEL

    assert_response :success
    assert_nil StashawayItem.order(:created_at).last.password
  end

  test "does not keep the password without encryption, even when asked" do
    StashawayItem.stubs(:encryption_ready?).returns(false)
    stub_login

    post stashaway_items_url, params: { stashaway_login: { email: "new@example.com", password: "secret", remember_password: "1" } }, headers: PANEL

    assert_response :success
    assert_nil StashawayItem.order(:created_at).last.password
  end

  test "signing an existing connection in again without the box forgets the saved password" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    @item.update!(password: "old-secret")
    @item.require_reauthentication!
    Provider::Stashaway.any_instance.stubs(:login).returns(Provider::Stashaway::Session.new(token: "login-token", user_id: "sa-user-1"))
    Provider::Stashaway.any_instance.stubs(:usable_token?).returns(true)

    post login_stashaway_item_url(@item), params: { stashaway_login: { password: "secret", remember_password: "0" } }, headers: PANEL

    assert_response :success
    @item.reload
    assert @item.ready_for_sync?
    assert_nil @item.password
  end

  test "forgetting the password keeps the connection and shows the panel without it" do
    @item.update!(password: "secret")

    post forget_password_stashaway_item_url(@item), headers: PANEL

    assert_response :success
    @item.reload
    assert_nil @item.password
    assert @item.ready_for_sync?
    assert_select "turbo-stream[target=stashaway-providers-panel] template form[action=?]", forget_password_stashaway_item_path(@item), count: 0
  end

  test "the forms offer to keep the password only when encryption is configured" do
    @item.require_reauthentication!

    StashawayItem.stubs(:encryption_ready?).returns(true)
    get connect_form_settings_providers_path(provider_key: "stashaway")
    assert_response :success
    assert_select "turbo-frame#stashaway-connect-form input[type=checkbox][name='stashaway_login[remember_password]']", 2 do |boxes|
      assert_equal 2, boxes.map { |box| box["id"] }.uniq.size
      assert boxes.none? { |box| box["checked"] }
    end

    StashawayItem.stubs(:encryption_ready?).returns(false)
    get connect_form_settings_providers_path(provider_key: "stashaway")
    assert_response :success
    assert_select "turbo-frame#stashaway-connect-form input[name='stashaway_login[remember_password]']", count: 0
    assert_select "turbo-frame#stashaway-connect-form", text: /the password cannot be kept for signing in again until encryption is configured/
  end

  test "the sign-in form of a connection with a saved password offers to keep it, ticked" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    @item.update!(password: "secret")
    @item.require_reauthentication!

    get connect_form_settings_providers_path(provider_key: "stashaway")

    assert_select "turbo-frame#stashaway-connect-form form[action=?] input[type=checkbox][checked]", login_stashaway_item_path(@item)
    assert_select "turbo-frame#stashaway-connect-form form[action=?] input[type=checkbox][checked]", stashaway_items_path, count: 0
  end

  private

    def stub_login
      Provider::Stashaway.any_instance.stubs(:login).returns(Provider::Stashaway::Session.new(token: "login-token", user_id: "sa-user-9"))
      Provider::Stashaway.any_instance.stubs(:usable_token?).with("login-token").returns(true)
    end
end
