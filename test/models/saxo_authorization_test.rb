require "test_helper"

class SaxoAuthorizationTest < ActiveSupport::TestCase
  setup do
    Setting.saxo_app_key = "application-key"
    @user = users(:family_admin)
  end

  test "state is single-use and bound to the initiating user and family" do
    state = SaxoAuthorization.begin!(user: @user, item: nil, redirect_uri: "https://sure.example/saxo_items/callback")
    assert_raises(ActiveRecord::RecordNotFound) { SaxoAuthorization.consume!(state: state, user: users(:family_member)) }
    assert_raises(ActiveRecord::RecordNotFound) { SaxoAuthorization.consume!(state: state, user: users(:empty)) }
    assert_equal @user.family_id, SaxoAuthorization.consume!(state: state, user: @user).family_id
    assert_raises(ActiveRecord::RecordNotFound) { SaxoAuthorization.consume!(state: state, user: @user) }
  end

  test "expired state cannot authorize a connection" do
    state = SaxoAuthorization.begin!(user: @user, item: nil, redirect_uri: "https://sure.example/saxo_items/callback")
    travel 11.minutes do
      assert_raises(Provider::Saxo::AuthenticationError) { SaxoAuthorization.consume!(state: state, user: @user) }
    end
  end
end
