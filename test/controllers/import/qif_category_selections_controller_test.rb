require "test_helper"

class Import::QifCategorySelectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "show warns about account types that are imported like a bank account" do
    import = qif_import_with(<<~QIF)
      !Type:Oth T
      D1/ 1'20
      T-25.00
      PGrocery Store
      ^
    QIF

    get import_qif_category_selection_url(import)

    assert_response :success
    assert_select "p", text: /Unknown account type/
    assert_select "div", text: /This QIF file contains the account type “Oth T”/
  end

  test "show does not warn about standard account types" do
    import = qif_import_with(<<~QIF)
      !Type:Bank
      D1/ 1'20
      T-25.00
      PGrocery Store
      ^
    QIF

    get import_qif_category_selection_url(import)

    assert_response :success
    assert_select "p", text: /Unknown account type/, count: 0
  end

  private
    def qif_import_with(content)
      import = QifImport.create!(family: @user.family, account: @account, raw_file_str: content)
      import.generate_rows_from_csv
      import
    end
end
