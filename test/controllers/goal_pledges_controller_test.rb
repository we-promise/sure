require "test_helper"

class GoalPledgesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    @goal = goals(:vacation_italy)
    @account = accounts(:depository)
    @pledge = goal_pledges(:open_transfer)
    ensure_tailwind_build
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get new_goal_pledge_url(@goal), headers: { "Turbo-Frame" => "modal" }

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "new renders the pledge form inside a turbo frame" do
    get new_goal_pledge_url(@goal), headers: { "Turbo-Frame" => "modal" }
    assert_response :success
  end

  test "new redirects to the goal show page on a non-frame GET" do
    get new_goal_pledge_url(@goal)
    assert_redirected_to goal_path(@goal)
  end

  test "create opens a pledge with default kind" do
    assert_difference -> { GoalPledge.count } => 1 do
      post goal_pledges_url(@goal), params: {
        goal_pledge: {
          amount: "150",
          account_id: @account.id
        }
      }
    end
    pledge = GoalPledge.order(created_at: :desc).first
    assert_equal "open", pledge.status
    assert_equal @goal.id, pledge.goal_id
    assert_redirected_to goal_path(@goal)
  end

  test "create rejects amount <= 0" do
    assert_no_difference "GoalPledge.count" do
      post goal_pledges_url(@goal), params: {
        goal_pledge: { amount: "0", account_id: @account.id }
      }
    end
    assert_response :unprocessable_entity
  end

  test "extend pushes expires_at forward" do
    before = @pledge.expires_at
    patch renew_goal_pledge_url(@goal, @pledge)
    assert_redirected_to goal_path(@goal)
    assert @pledge.reload.expires_at > before
  end

  test "extend on non-open pledge flashes alert" do
    pledge = goal_pledges(:matched_transfer)
    patch renew_goal_pledge_url(@goal, pledge)
    assert_redirected_to goal_path(@goal)
    assert flash[:alert].present?
  end

  test "destroy cancels an open pledge" do
    delete goal_pledge_url(@goal, @pledge)
    assert_redirected_to goal_path(@goal)
    assert @pledge.reload.status_cancelled?
  end

  test "destroy on non-open pledge flashes alert" do
    pledge = goal_pledges(:matched_transfer)
    delete goal_pledge_url(@goal, pledge)
    assert_redirected_to goal_path(@goal)
    assert flash[:alert].present?
  end

  test "another family's goal returns redirect" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_account = Account.create!(family: other_family, accountable: Depository.new, name: "Foreign", currency: "USD", balance: 100)
    other_goal = other_family.goals.new(name: "Foreign goal", target_amount: 100, currency: "USD")
    other_goal.goal_accounts.build(account: other_account)
    other_goal.save!

    get new_goal_pledge_url(other_goal)
    assert_redirected_to goals_path
  end

  test "pledge routes are not reachable for retirement goals" do
    retirement = Goal::Retirement.create!(
      family: @user.family, owner: @user,
      name: "Retire", target_amount: 1_000_000, currency: "USD"
    )

    get new_goal_pledge_url(retirement), headers: { "Turbo-Frame" => "modal" }

    assert_redirected_to goals_path
  end
end
