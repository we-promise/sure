require "test_helper"

class Settings::BudgetSharesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:empty)
    @owner = users(:josh)
    @viewer = users(:ann)
    sign_in @owner
  end

  test "grants a new share with the selected permission" do
    patch settings_budget_shares_url, params: {
      budget_shares: { members: { "0" => { viewer_id: @viewer.id, permission: "read_only" } } }
    }

    assert_redirected_to settings_preferences_path
    share = @owner.budget_shares_given.find_by(viewer: @viewer)
    assert_equal "read_only", share.permission
  end

  test "updates an existing share's permission" do
    BudgetShare.create!(owner: @owner, viewer: @viewer, permission: "read_only")

    patch settings_budget_shares_url, params: {
      budget_shares: { members: { "0" => { viewer_id: @viewer.id, permission: "read_write" } } }
    }

    assert_equal "read_write", @owner.budget_shares_given.find_by(viewer: @viewer).permission
  end

  test "revokes a share when permission is blank" do
    BudgetShare.create!(owner: @owner, viewer: @viewer, permission: "read_only")

    patch settings_budget_shares_url, params: {
      budget_shares: { members: { "0" => { viewer_id: @viewer.id, permission: "" } } }
    }

    assert_nil @owner.budget_shares_given.find_by(viewer: @viewer)
  end

  test "ignores a viewer_id outside the current user's family" do
    outsider = users(:family_admin)

    patch settings_budget_shares_url, params: {
      budget_shares: { members: { "0" => { viewer_id: outsider.id, permission: "read_only" } } }
    }

    assert_nil BudgetShare.find_by(owner: @owner, viewer: outsider)
  end
end
