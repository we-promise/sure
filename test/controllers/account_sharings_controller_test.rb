require "test_helper"

class AccountSharingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:family_admin)
    @member = users(:family_member)
    @account = accounts(:depository)
  end

  test "owner sets own and co-owner ownership percentages" do
    sign_in @owner

    patch account_sharing_url(@account), params: {
      owner_ownership_percentage: "60",
      sharing: { members: { "0" => { user_id: @member.id, shared: "1", permission: "read_only", ownership_percentage: "40" } } }
    }

    assert_equal 60, @account.reload.ownership_percentage
    assert_equal 40, @account.account_shares.find_by!(user: @member).ownership_percentage
  end

  test "rejects out of range ownership percentage" do
    sign_in @owner

    patch account_sharing_url(@account), params: { owner_ownership_percentage: "150" }

    assert_redirected_to account_url(@account)
    assert_equal 100, @account.reload.ownership_percentage
  end

  test "shared user cannot change ownership percentages" do
    sign_in @member
    share = @account.account_shares.find_by!(user: @member)

    patch account_sharing_url(@account), params: {
      owner_ownership_percentage: "10",
      sharing: { members: { "0" => { user_id: @member.id, shared: "1", ownership_percentage: "10" } } }
    }

    assert_redirected_to account_url(@account)
    assert_equal 100, @account.reload.ownership_percentage
    assert_equal 100, share.reload.ownership_percentage
  end

  test "owner sees editable ownership fields" do
    sign_in @owner

    get account_sharing_url(@account)

    assert_response :success
    # Inside .form-field, which supplies the border and padding of design system inputs
    assert_select ".form-field input.form-field__input[name='owner_ownership_percentage'][value='100.0']"
    assert_select ".form-field input.form-field__input[name$='[ownership_percentage]'][max='100']"
  end

  test "shared user sees their share as read-only text" do
    sign_in @member
    @account.account_shares.find_by!(user: @member).update!(ownership_percentage: 40)

    get account_sharing_url(@account)

    assert_response :success
    assert_select "input[name$='ownership_percentage']", count: 0
    assert_match "40%", response.body
  end

  test "invalid member percentage rolls back the owner percentage" do
    sign_in @owner

    patch account_sharing_url(@account), params: {
      owner_ownership_percentage: "60",
      sharing: { members: { "0" => { user_id: @member.id, shared: "1", ownership_percentage: "150" } } }
    }

    assert_redirected_to account_url(@account)
    assert_equal 100, @account.reload.ownership_percentage
  end

  test "blank member percentage is rejected instead of silently ignored" do
    sign_in @owner
    share = @account.account_shares.find_by!(user: @member)
    share.update!(ownership_percentage: 40)

    patch account_sharing_url(@account), params: {
      sharing: { members: { "0" => { user_id: @member.id, shared: "1", ownership_percentage: "" } } }
    }

    assert_redirected_to account_url(@account)
    assert_equal 40, share.reload.ownership_percentage
  end
end
