require "test_helper"

class StashawayItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @session = Provider::Stashaway::Session.new(token: "login-token", user_id: "sa-user-2")
  end

  test "a password step whose token serves data connects without a code" do
    item = new_item
    Provider::Stashaway.any_instance.expects(:login).with(email: "new@example.com", password: "secret", device_id: item.device_id).returns(@session)
    Provider::Stashaway.any_instance.expects(:usable_token?).with("login-token").returns(true)
    Provider::Stashaway.any_instance.expects(:send_two_factor_code).never

    assert_equal :connected, item.start_login!(password: "secret")

    item.reload
    assert item.ready_for_sync?
    assert_equal "login-token", item.api_token
    assert_equal "sa-user-2", item.stashaway_user_id
  end

  test "a password step StashAway does not serve data for sends the SMS code" do
    item = new_item
    Provider::Stashaway.any_instance.stubs(:login).returns(@session)
    Provider::Stashaway.any_instance.stubs(:usable_token?).returns(false)
    Provider::Stashaway.any_instance.expects(:send_two_factor_code).with(token: "login-token").returns(true)

    assert_equal :code_sent, item.start_login!(password: "secret")

    item.reload
    assert item.login_pending?
    assert_not item.ready_for_sync?
    assert_nil item.api_token
  end

  test "StashAway asking for 2FA sends the SMS code without trying the token for data" do
    item = new_item
    Provider::Stashaway.any_instance.stubs(:login)
      .returns(Provider::Stashaway::Session.new(token: "pre-2fa-token", user_id: "sa-user-2", two_factor_required: true))
    Provider::Stashaway.any_instance.expects(:usable_token?).never
    Provider::Stashaway.any_instance.expects(:send_two_factor_code).with(token: "pre-2fa-token").returns(true)

    assert_equal :code_sent, item.start_login!(password: "secret")

    item.reload
    assert item.login_pending?
    assert_equal "pre-2fa-token", item.pending_login_token
    assert_nil item.api_token
  end

  test "the code completes the sign-in with the same device id" do
    item = pending_item
    Provider::Stashaway.any_instance.expects(:verify_two_factor)
      .with(code: "123456", token: "login-token", device_id: item.device_id).returns("api-token")

    assert_equal :connected, item.complete_login!(code: "123456")

    item.reload
    assert item.good?
    assert_equal "api-token", item.api_token
    assert_nil item.pending_login_token
  end

  test "a refused code keeps the sign-in open for another try" do
    item = pending_item
    Provider::Stashaway.any_instance.stubs(:verify_two_factor).raises(Provider::Stashaway::InvalidCode, "Invalid OTP")

    assert_raises(Provider::Stashaway::InvalidCode) { item.complete_login!(code: "000000") }

    assert item.reload.login_pending?
  end

  test "a code entered after the sign-in window is refused without asking StashAway" do
    item = pending_item
    Provider::Stashaway.any_instance.expects(:verify_two_factor).never

    travel 11.minutes do
      assert item.login_expired?
      assert_raises(StashawayItem::Authentication::LoginExpired) { item.complete_login!(code: "123456") }
    end
  end

  test "a refused password saves nothing" do
    item = new_item
    Provider::Stashaway.any_instance.stubs(:login).raises(Provider::Stashaway::InvalidCredentials, "Incorrect email or password")

    assert_no_difference "StashawayItem.count" do
      assert_raises(Provider::Stashaway::InvalidCredentials) { item.start_login!(password: "wrong") }
    end
  end

  test "a StashAway login already connected in the family is refused" do
    Provider::Stashaway.any_instance.stubs(:login).returns(Provider::Stashaway::Session.new(token: "t", user_id: "sa-user-1"))

    assert_raises(StashawayItem::Authentication::AlreadyConnected) { new_item.start_login!(password: "secret") }
  end

  test "the same StashAway user id in another region is another login" do
    Provider::Stashaway.any_instance.stubs(:login).returns(Provider::Stashaway::Session.new(token: "t", user_id: "sa-user-1"))
    Provider::Stashaway.any_instance.stubs(:usable_token?).returns(true)
    item = new_item(region: "my")

    assert_equal :connected, item.start_login!(password: "secret")

    assert_equal [ "my", "sa-user-1" ], [ item.reload.region, item.stashaway_user_id ]
  end

  test "a login StashAway names no user id for is matched on its email" do
    Provider::Stashaway.any_instance.stubs(:login).returns(Provider::Stashaway::Session.new(token: "t", two_factor_required: true))
    Provider::Stashaway.any_instance.expects(:send_two_factor_code).never

    assert_raises(StashawayItem::Authentication::AlreadyConnected) { new_item(email: "Investor@Example.com").start_login!(password: "secret") }
  end

  test "the same email in another region is another login" do
    Provider::Stashaway.any_instance.stubs(:login).returns(Provider::Stashaway::Session.new(token: "t"))
    Provider::Stashaway.any_instance.stubs(:usable_token?).returns(true)
    item = new_item(region: "my", email: "investor@example.com")

    assert_equal :connected, item.start_login!(password: "secret")

    assert_nil item.reload.stashaway_user_id
  end

  test "signing in again without a user id keeps the connection's own" do
    item = stashaway_items(:connected)
    Provider::Stashaway.any_instance.stubs(:login).returns(Provider::Stashaway::Session.new(token: "t"))
    Provider::Stashaway.any_instance.stubs(:usable_token?).returns(true)

    assert_equal :connected, item.start_login!(password: "secret")

    assert_equal "sa-user-1", item.reload.stashaway_user_id
  end

  test "a login connected while StashAway was answering is refused before it is saved" do
    item = new_item
    family = @family
    client = Object.new
    client.define_singleton_method(:login) { |**| Provider::Stashaway::Session.new(token: "t", user_id: "sa-user-9") }
    # The other sign-in of the same login lands between the first check and the save.
    client.define_singleton_method(:usable_token?) do |_token|
      family.stashaway_items.create!(email: "new@example.com", name: "StashAway", region: "sg", stashaway_user_id: "sa-user-9", api_token: "t")
      true
    end
    item.stubs(:stashaway_client).returns(client)

    assert_raises(StashawayItem::Authentication::AlreadyConnected) { item.start_login!(password: "secret") }

    assert_not item.persisted?
  end

  test "signs in on the item's region" do
    item = new_item(region: "th")
    Provider::Stashaway.expects(:new).with(region: "th", token: nil).returns(client = mock)
    client.expects(:login).returns(@session)
    client.expects(:usable_token?).returns(true)

    item.start_login!(password: "secret")
  end

  test "only StashAway's regions are accepted" do
    item = new_item(region: "us")

    assert_not item.valid?
    assert item.errors.added?(:region, :inclusion, value: "us")
  end

  test "is named after its region" do
    assert_equal "StashAway Singapore", stashaway_items(:connected).institution_display_name
    assert_equal "StashAway MENA", new_item(region: "ae").institution_display_name
  end

  test "signing in again must reach the same StashAway login" do
    item = stashaway_items(:connected)
    Provider::Stashaway.any_instance.stubs(:login).returns(@session)

    assert_raises(StashawayItem::Authentication::AccountMismatch) { item.start_login!(password: "secret") }
  end

  test "unlinking forgets where the import into the account started and the balance it measured from" do
    stashaway_account = stashaway_accounts(:general)
    stashaway_account.link_to!(accounts(:investment))
    stashaway_account.update!(import_start_date: Date.new(2026, 2, 1), import_base: 5)

    stashaway_items(:connected).unlink_all!

    stashaway_account.reload
    assert_nil stashaway_account.current_account
    assert_nil stashaway_account.import_start_date
    assert_nil stashaway_account.import_base
  end

  test "the password is saved when asked and encryption is configured" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    item = new_item
    Provider::Stashaway.any_instance.stubs(:login).returns(@session)
    Provider::Stashaway.any_instance.stubs(:usable_token?).returns(true)

    assert_equal :connected, item.start_login!(password: "secret", remember: true)

    item.reload
    assert item.password_saved?
    assert_equal "secret", item.password
  end

  test "the password is saved while StashAway's code is awaited" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    item = new_item
    Provider::Stashaway.any_instance.stubs(:login).returns(Provider::Stashaway::Session.new(token: "pre-2fa-token", two_factor_required: true))
    Provider::Stashaway.any_instance.stubs(:send_two_factor_code).returns(true)

    assert_equal :code_sent, item.start_login!(password: "secret", remember: true)

    assert_equal "secret", item.reload.password
  end

  test "the password is not saved unless asked" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    item = new_item
    Provider::Stashaway.any_instance.stubs(:login).returns(@session)
    Provider::Stashaway.any_instance.stubs(:usable_token?).returns(true)

    item.start_login!(password: "secret")

    assert_not item.reload.password_saved?
  end

  test "the password is not saved without encryption" do
    StashawayItem.stubs(:encryption_ready?).returns(false)
    item = new_item
    Provider::Stashaway.any_instance.stubs(:login).returns(@session)
    Provider::Stashaway.any_instance.stubs(:usable_token?).returns(true)

    item.start_login!(password: "secret", remember: true)

    assert_not item.reload.password_saved?
  end

  test "signing in again without asking forgets the saved password" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    item = stashaway_items(:connected)
    item.update!(password: "old-secret")
    Provider::Stashaway.any_instance.stubs(:login).returns(Provider::Stashaway::Session.new(token: "t"))
    Provider::Stashaway.any_instance.stubs(:usable_token?).returns(true)

    item.start_login!(password: "secret")

    assert_nil item.reload.password
  end

  test "a refused password changes nothing about the saved one" do
    StashawayItem.stubs(:encryption_ready?).returns(true)
    item = stashaway_items(:connected)
    item.update!(password: "old-secret")
    Provider::Stashaway.any_instance.stubs(:login).raises(Provider::Stashaway::InvalidCredentials, "Incorrect email or password")

    assert_raises(Provider::Stashaway::InvalidCredentials) { item.start_login!(password: "wrong", remember: true) }

    assert_equal "old-secret", item.reload.password
  end

  test "forgetting the password keeps the connection" do
    item = stashaway_items(:connected)
    item.update!(password: "secret")

    item.forget_password!

    item.reload
    assert_nil item.password
    assert item.ready_for_sync?
  end

  test "needing a new sign-in keeps the saved password" do
    item = stashaway_items(:connected)
    item.update!(password: "secret")

    item.require_reauthentication!

    item.reload
    assert item.requires_update?
    assert_equal "secret", item.password
  end

  test "a connection with a saved password stays syncable without a token until a code is awaited" do
    item = stashaway_items(:connected)
    item.update!(password: "secret")
    item.require_reauthentication!

    assert StashawayItem.syncable.exists?(item.id)

    item.update!(pending_login_token: "login-token", pending_login_started_at: Time.current)
    assert_not StashawayItem.syncable.exists?(item.id)
  end

  test "declares the password as encrypted" do
    skip "Encryption not configured" unless StashawayItem.encryption_ready?

    assert_includes StashawayItem.encrypted_attributes.map(&:to_s), "password"
  end

  private

    def new_item(region: "sg", email: "new@example.com")
      @family.stashaway_items.build(email: email, name: "StashAway", region: region, status: :requires_update).tap(&:validate)
    end

    def pending_item
      @family.stashaway_items.create!(
        email: "pending@example.com",
        name: "StashAway",
        status: :requires_update,
        pending_login_token: "login-token",
        pending_login_started_at: Time.current
      )
    end
end
