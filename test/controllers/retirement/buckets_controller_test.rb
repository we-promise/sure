require "test_helper"

class Retirement::BucketsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @user.family.update!(retirement_disabled: false)
    sign_in @user
    ensure_tailwind_build
    @plan = Goal::Retirement.for_owner(@user)
  end

  test "update replaces the selected accounts" do
    keep = accounts(:investment)
    add = accounts(:depository)

    patch retirement_bucket_url, params: { bucket: { account_ids: [ keep.id, add.id ] } }

    assert_redirected_to retirement_path
    assert_equal [ add.id, keep.id ].sort, @plan.retirement_bucket_entries.pluck(:account_id).sort
  end

  test "update with empty selection clears the bucket" do
    patch retirement_bucket_url, params: { bucket: { account_ids: [] } }
    assert_equal 0, @plan.retirement_bucket_entries.count
  end

  test "ignores accounts from another family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    foreign = Account.create!(family: other_family, accountable: Depository.new, name: "Foreign", currency: "USD", balance: 1)

    patch retirement_bucket_url, params: { bucket: { account_ids: [ foreign.id ] } }

    assert_not_includes @plan.retirement_bucket_entries.pluck(:account_id), foreign.id
  end
end
