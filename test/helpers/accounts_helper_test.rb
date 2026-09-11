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

  # A background broadcast renders these partials with no `Current.user`. The
  # empty-set fallback collapses "no viewer" into "no accessible accounts",
  # which replaced a populated provider card with an empty one — the accounts
  # looking deleted rather than merely unrendered.
  test "knows the difference between no viewer and a viewer who sees nothing" do
    Current.session = nil

    assert_not viewer_present_for_account_scoping?,
      "a job with no viewer was treated as a viewer who may see nothing"
  end

  test "a signed-in viewer is a viewer even with nothing shared" do
    Current.session = @session

    assert viewer_present_for_account_scoping?
  end

  # The index injects the list, and the partial must still scope to it even
  # where `Current.user` has not been reached for.
  test "an injected list counts as a viewer" do
    Current.session = nil
    @accessible_account_ids = [ @owned.id ]

    assert viewer_present_for_account_scoping?
  end

  # The whole point: with no viewer the card must not come back empty, because
  # an empty provider card reads as "your accounts are gone" rather than "this
  # is waiting on a refresh".
  test "the groups partial asks for the rows back rather than showing nothing" do
    Current.session = nil

    render partial: "accounts/index/account_groups", locals: { accounts: [ @owned, @someone_elses ] }

    assert_includes rendered, "account-groups-awaiting-refresh"
    assert_includes rendered, account_groups_frame_id([ @owned.id, @someone_elses.id ])
    assert_includes rendered, "/accounts/groups"
    assert_not_includes rendered, @someone_elses.name
    assert_not_includes rendered, @owned.name
  end

  # Both sides derive the id from what was REQUESTED. Keying it on the filtered
  # result would give the reply a different id from the frame waiting for it,
  # and the rows would never land.
  test "the frame id does not depend on the order the accounts arrive in" do
    assert_equal account_groups_frame_id([ @owned.id, @someone_elses.id ]),
                 account_groups_frame_id([ @someone_elses.id, @owned.id ])
  end

  test "the frame id distinguishes different sets of accounts" do
    assert_not_equal account_groups_frame_id([ @owned.id ]),
                     account_groups_frame_id([ @owned.id, @someone_elses.id ])
  end

  # An empty injected list is still a viewer: one who may see nothing. Read as
  # "no viewer", a member with no shared accounts would get an "Updating…"
  # card that never updates into anything.
  test "an injected empty list is a viewer who sees nothing" do
    Current.session = nil
    @accessible_account_ids = []

    assert viewer_present_for_account_scoping?
    assert_empty accounts_visible_to_viewer([ @owned, @someone_elses ])
  end
end
