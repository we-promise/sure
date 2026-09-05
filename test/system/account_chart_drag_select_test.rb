require "application_system_test_case"

class AccountChartDragSelectTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "dragging across the balance chart navigates to the dragged date range" do
    sign_in @user

    visit account_url(@account)
    assert_text @account.name

    drag_across find("#lineChart .drag-select-brush .overlay", visible: :all)

    assert_current_path(%r{/accounts/#{@account.id}\?.*start_date=.*end_date=})
  end
end
