require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  setup do
    @user = users(:family_admin)
    @session = sessions(:one)
    @owned = accounts(:investment)
    @someone_elses = accounts(:credit_card)

    @someone_elses.account_shares.destroy_all
    @someone_elses.update!(owner: users(:family_member))
    @owned.update!(owner: @user)
  end

  test "keeps only the accounts the viewer may see" do
    Current.session = @session

    visible = accounts_visible_to_viewer([ @owned, @someone_elses ])

    assert_equal [ @owned ], visible
  end

  # The accounts index has already loaded this list, so the helper reuses it
  # rather than repeating the query for every provider card on the page.
  test "prefers the list the controller already loaded" do
    Current.session = @session
    @accessible_account_ids = [ @someone_elses.id ]

    visible = accounts_visible_to_viewer([ @owned, @someone_elses ])

    assert_equal [ @someone_elses ], visible,
      "the controller's list should win, and be read rather than recomputed"
  end

  # SimpleFIN and Kraken re-render these partials from their own controllers,
  # which never set that ivar, so the fallback is a live path rather than a
  # defensive one.
  test "falls back to a query when no controller list is present" do
    Current.session = @session

    assert_nil @accessible_account_ids
    assert_equal [ @owned ], accounts_visible_to_viewer([ @owned, @someone_elses ])
  end

  # Signed out there is no viewer to authorise, and showing everything would be
  # the wrong way to fail.
  test "shows nothing when there is no viewer" do
    Current.session = nil

    assert_empty accounts_visible_to_viewer([ @owned, @someone_elses ])
  end

  test "an account shared with the viewer is theirs to see" do
    Current.session = @session
    @someone_elses.account_shares.create!(user: @user, permission: "read_only")

    visible = accounts_visible_to_viewer([ @owned, @someone_elses ])

    assert_includes visible, @someone_elses
  end
end
