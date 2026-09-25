require "test_helper"

class Import::CleansControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "shows if configured" do
    import = imports(:transaction)

    TransactionImport.any_instance.stubs(:configured?).returns(true)

    get import_clean_path(import)
    assert_response :success
    assert_select "[data-action='click->privacy-mode#toggle']", count: 1
  end

  test "redirects if not configured" do
    import = imports(:transaction)

    TransactionImport.any_instance.stubs(:configured?).returns(false)

    get import_clean_path(import)
    assert_redirected_to import_configuration_path(import)
  end

  test "hides the source PDF beside PDF import rows by default" do
    import = imports(:pdf_with_rows)
    import.pdf_file.attach(
      io: File.open(file_fixture("imports/sample_bank_statement.pdf")),
      filename: "sample_bank_statement.pdf",
      content_type: "application/pdf"
    )

    get import_clean_path(import)

    assert_response :success
    assert_select "h2", text: "Source PDF"
    assert_select "iframe", count: 0
  end

  test "shows the source PDF when requested" do
    import = imports(:pdf_with_rows)
    import.pdf_file.attach(
      io: File.open(file_fixture("imports/sample_bank_statement.pdf")),
      filename: "sample_bank_statement.pdf",
      content_type: "application/pdf"
    )

    get import_clean_path(import, show_pdf: "1")

    assert_response :success
    assert_select "iframe[src='#{preview_import_path(import)}']"
  end

  test "does not show a source PDF for non-PDF imports" do
    import = imports(:transaction)
    TransactionImport.any_instance.stubs(:configured?).returns(true)

    get import_clean_path(import)

    assert_response :success
    assert_select "iframe", count: 0
  end

  test "can hide the source PDF and show all rows" do
    import = imports(:pdf_with_rows)
    import.pdf_file.attach(
      io: File.open(file_fixture("imports/sample_bank_statement.pdf")),
      filename: "sample_bank_statement.pdf",
      content_type: "application/pdf"
    )

    get import_clean_path(import, per_page: "all")

    assert_response :success
    assert_select "iframe", count: 0
    assert_select "select[name='per_page'] option[value='all'][selected]"
    assert_select "[data-import-clean-layout-target='showPdfControl']"
  end
end
