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

  # Month-first dates with dots: read as day-first, only "7.10.20" is a valid
  # date, so the "Rent" transaction on "7.25.20" is missing until the user
  # switches to MM.DD.YYYY.
  DOTTED_MONTH_FIRST_QIF = <<~QIF
    !Type:Bank
    D7.10.20
    T-10.00
    PGrocery Store
    LFood/Holiday
    ^
    D7.25.20
    T-500.00
    PLandlord
    LRent/Home
    ^
  QIF

  test "update shows the selection again when the new date format brings new categories and tags" do
    import = qif_import_with(DOTTED_MONTH_FIRST_QIF, date_format: "%d.%m.%Y")
    assert_equal [ "Food" ], import.row_categories

    put import_qif_category_selection_url(import), params: {
      date_format: "%m.%d.%Y", categories: [ "Food" ], tags: [ "Holiday" ]
    }

    assert_redirected_to import_qif_category_selection_url(import)
    import.reload
    assert_equal "%m.%d.%Y", import.qif_date_format
    assert_equal({ "Grocery Store" => "Food", "Landlord" => "Rent" }, import.rows.pluck(:name, :category).to_h)
    assert_equal({ "Grocery Store" => "Holiday", "Landlord" => "Home" }, import.rows.pluck(:name, :tags).to_h)
    assert_nil import.column_mappings["qif_selected_categories"]

    follow_redirect!

    assert_response :success
    assert_select "div", text: /Categories and tags have changed/
    assert_select "input[name='categories[]'][value='Rent'][checked]"
    assert_select "input[name='tags[]'][value='Home'][checked]"
  end

  test "update shows the selection again when the new date format brings new split categories" do
    import = qif_import_with(<<~QIF, date_format: "%d.%m.%Y")
      !Type:Bank
      D7.10.20
      T-10.00
      PGrocery Store
      LFood
      ^
      D7.25.20
      T-500.00
      PLandlord
      SRent
      $-400.00
      SUtilities
      $-100.00
      ^
    QIF
    assert_equal [ "Food" ], import.row_categories

    put import_qif_category_selection_url(import), params: { date_format: "%m.%d.%Y", categories: [ "Food" ] }

    assert_redirected_to import_qif_category_selection_url(import)
    assert_equal [ "Food", "Rent", "Utilities" ], QifImport.find(import.id).row_categories
  end

  test "update offers new split categories after a format change on a revisited selection" do
    import = qif_import_with(<<~QIF, date_format: "%d.%m.%Y")
      !Type:Bank
      D7.10.20
      T-10.00
      PGrocery Store
      LFood
      ^
      D7.25.20
      T-500.00
      PLandlord
      SRent
      $-400.00
      SUtilities
      $-100.00
      ^
    QIF
    put import_qif_category_selection_url(import), params: { date_format: "%d.%m.%Y", categories: [ "Food" ] }
    assert_redirected_to import_clean_url(import)
    assert_equal [ "Food" ], import.reload.column_mappings["qif_selected_categories"]

    put import_qif_category_selection_url(import), params: { date_format: "%m.%d.%Y", categories: [ "Food" ] }

    assert_redirected_to import_qif_category_selection_url(import)
    assert_nil import.reload.column_mappings["qif_selected_categories"]
    assert_equal [ "Food", "Rent", "Utilities" ], QifImport.find(import.id).row_categories

    follow_redirect!

    assert_select "input[name='categories[]'][value='Utilities'][checked]"
  end

  test "update applies the selection when the new date format keeps the same categories and tags" do
    import = qif_import_with(<<~QIF, date_format: "%d.%m.%Y")
      !Type:Bank
      D1.2.20
      T-10.00
      PGrocery Store
      LFood
      ^
      D3.4.20
      T-500.00
      PLandlord
      LRent
      ^
    QIF

    put import_qif_category_selection_url(import), params: { date_format: "%m.%d.%Y", categories: [ "Rent" ] }

    assert_redirected_to import_clean_url(import)
    import.reload
    assert_equal "%m.%d.%Y", import.qif_date_format
    assert_equal "2020-01-02", import.rows.find_by(name: "Grocery Store").date
    assert_equal({ "Grocery Store" => "", "Landlord" => "Rent" }, import.rows.pluck(:name, :category).to_h)
    assert_equal [ "Rent" ], import.column_mappings["qif_selected_categories"]
  end

  test "update clears deselected categories and tags when the date format stays the same" do
    import = qif_import_with(DOTTED_MONTH_FIRST_QIF, date_format: "%m.%d.%Y")

    put import_qif_category_selection_url(import), params: {
      date_format: "%m.%d.%Y", categories: [ "Rent" ], tags: [ "Home" ]
    }

    assert_redirected_to import_clean_url(import)
    import.reload
    assert_equal({ "Grocery Store" => "", "Landlord" => "Rent" }, import.rows.pluck(:name, :category).to_h)
    assert_equal({ "Grocery Store" => "", "Landlord" => "Home" }, import.rows.pluck(:name, :tags).to_h)
    assert_equal [ "Rent" ], import.column_mappings["qif_selected_categories"]
    assert_equal [ "Home" ], import.column_mappings["qif_selected_tags"]
  end

  test "show does not report changed lists on a normal visit" do
    import = qif_import_with(DOTTED_MONTH_FIRST_QIF, date_format: "%m.%d.%Y")

    get import_qif_category_selection_url(import)

    assert_response :success
    assert_select "div", text: /Categories and tags have changed/, count: 0
  end

  private
    def qif_import_with(content, date_format: nil)
      import = QifImport.create!(family: @user.family, account: @account, raw_file_str: content)
      import.generate_rows_from_csv
      if date_format
        import.qif_date_format = date_format
        import.save!(validate: false)
        import.generate_rows_from_csv
      end
      import
    end
end
