require "test_helper"

class Import::ConfirmsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    ensure_tailwind_build
  end

  test "shows if cleaned" do
    import = imports(:transaction)

    TransactionImport.any_instance.stubs(:cleaned?).returns(true)

    get import_confirm_path(import)
    assert_response :success
  end

  test "localizes mapping step labels in German" do
    import = imports(:transaction)
    @user.update!(locale: "de")
    TransactionImport.any_instance.stubs(:cleaned?).returns(true)

    get import_confirm_path(import)

    assert_response :success
    assert_select "span.sr-only", text: "Schritt 1", count: 1
    assert_select "span.sr-only", text: "Schritt 2", count: 1
    assert_select "span.sr-only", text: "Schritt 3", count: 1
  end

  test "preserves mapping step labels in English" do
    import = imports(:transaction)
    @user.update!(locale: "en")
    TransactionImport.any_instance.stubs(:cleaned?).returns(true)

    get import_confirm_path(import)

    assert_response :success
    assert_select "span.sr-only", text: "Step 1", count: 1
    assert_select "span.sr-only", text: "Step 2", count: 1
    assert_select "span.sr-only", text: "Step 3", count: 1
  end

  test "redirects if not cleaned" do
    import = imports(:transaction)

    TransactionImport.any_instance.stubs(:cleaned?).returns(false)

    get import_confirm_path(import)
    assert_redirected_to import_clean_path(import)
    assert_equal "You have invalid data, please edit until all errors are resolved", flash[:alert]
  end
end
