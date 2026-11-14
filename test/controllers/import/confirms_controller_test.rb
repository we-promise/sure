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

  test "renders the security mapping step for a trade import" do
    import = imports(:trade)
    import.update!(
      account: accounts(:depository),
      raw_file_str: "date,ticker,qty,price,currency,name\n01/01/2024,AAPL,10,150.00,USD,Apple Buy\n",
      date_col_label: "date",
      ticker_col_label: "ticker",
      qty_col_label: "qty",
      price_col_label: "price",
      date_format: "%m/%d/%Y",
      signage_convention: "inflows_positive"
    )
    import.generate_rows_from_csv
    import.sync_mappings
    TradeImport.any_instance.stubs(:cleaned?).returns(true)
    Security.stubs(:providers).returns([ :synth ])

    security_step = import.mapping_steps.index(Import::SecurityMapping) + 1

    get import_confirm_path(import, step: security_step)

    assert_response :success
    assert_select "span.sr-only", text: "Step #{security_step}"
  end

  test "redirects if not cleaned" do
    import = imports(:transaction)

    TransactionImport.any_instance.stubs(:cleaned?).returns(false)

    get import_confirm_path(import)
    assert_redirected_to import_clean_path(import)
    assert_equal "You have invalid data, please edit until all errors are resolved", flash[:alert]
  end
end
