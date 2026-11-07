require "test_helper"

class OnboardingChoicesTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @user.update!(created_at: 5.days.ago)
  end

  test "normalizes starting tools and preserves unrelated preferences" do
    @user.preferences = { "preview_features_enabled" => true }
    @user.update!(starting_tools: [ "", "ynab", "ynab", "other" ], starting_tool_other: "  My app  ")
    assert_equal [ "ynab", "other" ], @user.reload.starting_tools
    assert_equal "My app", @user.starting_tool_other
    assert @user.preview_features_enabled?
  end

  test "rejects conflicting unknown and malformed starting tools" do
    [ [ "nothing_yet", "ynab" ], [ "unknown" ], "ynab", { "ynab" => true } ].each do |value|
      @user.starting_tools = value
      assert_not @user.valid?
      assert @user.errors[:starting_tools].present?
    end
    @user.starting_tools = [ "nothing_yet" ]
    assert @user.valid?
  end

  test "bounds other text and clears it when deselected" do
    @user.assign_attributes(starting_tools: [ "other" ], starting_tool_other: "x" * 61)
    assert_not @user.valid?
    @user.update!(starting_tools: [ "ynab" ])
    assert_nil @user.reload.starting_tool_other
  end

  test "mode controls only this user's assistant" do
    family_attributes = @user.family.attributes
    other_ai = users(:family_member).ai_enabled
    { "none" => false, "builtin" => true, "external" => false }.each do |mode, enabled|
      assert @user.update_onboarding_choices(onboarding_ai_mode: mode)
      assert_equal mode, @user.reload.onboarding_ai_mode
      assert_equal enabled, @user.ai_enabled
    end
    assert_equal family_attributes, @user.family.reload.attributes
    assert_equal other_ai, users(:family_member).reload.ai_enabled
  end

  test "existing users default to none without changing AI on unrelated updates" do
    preferences = @user.preferences.deep_dup
    enabled = @user.ai_enabled
    assert_equal "none", @user.onboarding_ai_mode
    @user.update!(first_name: "Updated")
    assert_equal preferences, @user.reload.preferences
    assert_equal enabled, @user.ai_enabled
  end

  test "builtin still requires the existing assistant availability gate" do
    assert @user.update_onboarding_choices(onboarding_ai_mode: "builtin")
    @user.stubs(:ai_available?).returns(false)
    assert @user.ai_enabled
    assert_not @user.ai_enabled?
  end

  test "guest role defaults cannot undo the submitted assistant choice" do
    guest = users(:intro_user)
    %w[none external].each do |mode|
      assert guest.update_onboarding_choices(onboarding_ai_mode: mode)
      guest.update!(first_name: "Updated")
      assert_not guest.reload.ai_enabled
    end
    guest.update!(ai_enabled: true)
    guest.update!(first_name: "Updated again")
    assert guest.reload.ai_enabled
  end

  test "first family completion captures once and keeps its original intent" do
    @user.family.users.update_all(onboarded_at: nil, set_onboarding_goals_at: nil)
    Usage.expects(:capture_onboarding_ai_intent).with(family_id: @user.family_id, mode: "none").once
    assert @user.update_onboarding_choices(completion("none"))
    assert @user.update_onboarding_choices(completion("builtin"))
    assert_equal "none", @user.family.reload.initial_onboarding_ai_mode
  end

  test "initial intent does not revalidate unrelated legacy family preferences" do
    @user.family.users.update_all(onboarded_at: nil, set_onboarding_goals_at: nil)
    @user.family.update_columns(locale: "legacy-unsupported", date_format: "legacy-format")
    Usage.expects(:capture_onboarding_ai_intent).with(family_id: @user.family_id, mode: "none").once

    assert @user.update_onboarding_choices(completion("none"))
    assert_equal "none", @user.family.reload.initial_onboarding_ai_mode
    assert_equal "legacy-unsupported", @user.family.locale
    assert_equal "legacy-format", @user.family.date_format
  end

  test "invalid completion does not consume initial intent" do
    @user.family.users.update_all(onboarded_at: nil, set_onboarding_goals_at: nil)
    Usage.expects(:capture_onboarding_ai_intent).never
    assert_not @user.update_onboarding_choices(completion("invalid"))
    assert_nil @user.reload.onboarded_at
    assert_nil @user.family.reload.initial_onboarding_ai_mode
  end

  test "members and established families do not capture initial intent" do
    Usage.expects(:capture_onboarding_ai_intent).never
    member = users(:family_member)
    member.update!(onboarded_at: nil, set_onboarding_goals_at: nil)
    assert member.update_onboarding_choices(completion("external"))
    @user.update!(onboarded_at: nil, set_onboarding_goals_at: nil)
    assert @user.update_onboarding_choices(completion("builtin"))
  end

  test "invited administrators cannot claim the family's initial intent" do
    @user.family.users.update_all(onboarded_at: nil, set_onboarding_goals_at: nil)
    invited = users(:family_member)
    invited.update!(role: "admin", created_at: 6.days.ago)
    @user.family.invitations.create!(inviter: @user, email: invited.email, role: "admin", accepted_at: Time.current)
    Usage.expects(:capture_onboarding_ai_intent).never
    assert invited.update_onboarding_choices(completion("external"))
    assert_nil @user.family.reload.initial_onboarding_ai_mode
  end

  test "a durable family claim is not reopened after the original user moves" do
    @user.family.users.update_all(onboarded_at: nil, set_onboarding_goals_at: nil)
    Usage.expects(:capture_onboarding_ai_intent).with(family_id: @user.family_id, mode: "none").once
    assert @user.update_onboarding_choices(completion("none"))
    original_family = @user.family
    @user.update!(family: families(:empty))
    next_admin = users(:family_member)
    next_admin.update!(role: "admin")
    assert next_admin.update_onboarding_choices(completion("builtin"))
    assert_equal "none", original_family.reload.initial_onboarding_ai_mode
  end

  test "only the earliest family user can record initial intent" do
    @user.family.users.update_all(onboarded_at: nil, set_onboarding_goals_at: nil)
    another_admin = users(:family_member)
    another_admin.update!(role: "admin")
    Usage.expects(:capture_onboarding_ai_intent).never
    assert another_admin.update_onboarding_choices(completion("builtin"))
    assert_nil @user.family.reload.initial_onboarding_ai_mode
  end

  test "disabled collection consumes initial completion without later backfill" do
    previous_client = $posthog_feedback
    $posthog_feedback = mock("feedback collector")
    $posthog_feedback.expects(:capture).never
    Rails.env.stubs(:production?).returns(true)
    Rails.configuration.x.posthog.stubs(:feedback_enabled).returns(false)
    @user.family.users.update_all(onboarded_at: nil, set_onboarding_goals_at: nil)

    assert @user.update_onboarding_choices(completion("none"))
    assert_equal "none", @user.family.reload.initial_onboarding_ai_mode
    Rails.configuration.x.posthog.stubs(:feedback_enabled).returns(true)
    assert @user.update_onboarding_choices(completion("builtin"))
    assert_equal "none", @user.family.reload.initial_onboarding_ai_mode
  ensure
    $posthog_feedback = previous_client
  end

  private
    def completion(mode)
      { onboarding_ai_mode: mode, onboarded_at: Time.current, set_onboarding_goals_at: Time.current }
    end
end
