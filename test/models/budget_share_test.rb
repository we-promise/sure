require "test_helper"

class BudgetShareTest < ActiveSupport::TestCase
  setup do
    @owner = users(:josh)
    @viewer = users(:ann)
  end

  test "valid with a family member and a permitted permission" do
    share = BudgetShare.new(owner: @owner, viewer: @viewer, permission: "read_only")

    assert share.valid?
  end

  test "invalid with a permission outside PERMISSIONS" do
    share = BudgetShare.new(owner: @owner, viewer: @viewer, permission: "full_control")

    assert_not share.valid?
  end

  test "invalid sharing with yourself" do
    share = BudgetShare.new(owner: @owner, viewer: @owner, permission: "read_only")

    assert_not share.valid?
  end

  test "invalid across families" do
    outsider = users(:family_admin)
    share = BudgetShare.new(owner: @owner, viewer: outsider, permission: "read_only")

    assert_not share.valid?
  end

  test "invalid with a duplicate owner/viewer pair" do
    BudgetShare.create!(owner: @owner, viewer: @viewer, permission: "read_only")
    duplicate = BudgetShare.new(owner: @owner, viewer: @viewer, permission: "read_write")

    assert_not duplicate.valid?
  end

  test "read_write? and read_only? reflect the permission" do
    share = BudgetShare.new(owner: @owner, viewer: @viewer, permission: "read_write")

    assert share.read_write?
    assert_not share.read_only?
  end
end
