require "test_helper"

class ImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "gets index" do
    get imports_url

    assert_response :success

    @user.family.imports.ordered.each do |import|
      assert_select "#" + dom_id(import), count: 1
    end
  end

  test "gets new" do
    get new_import_url

    assert_response :success

    assert_select "turbo-frame#modal"
  end

  test "shows disabled account-dependent imports when family has no accounts" do
    sign_in users(:empty)

    get new_import_url

    assert_response :success
    assert_select "button", text: "Import accounts"
    assert_select "button", text: "Import transactions", count: 0
    assert_select "button", text: "Import investments", count: 0
    assert_select "button", text: "Import from Mint", count: 0
    assert_select "span", text: "Import accounts first to unlock this option.", count: 3
    assert_select "div[aria-disabled=true]", count: 3
  end

  test "creates import" do
    assert_difference "Import.count", 1 do
      post imports_url, params: {
        import: {
          type: "TransactionImport"
        }
      }
    end

    assert_redirected_to import_upload_url(Import.all.ordered.first)
  end

  test "uploads supported non-pdf document for vector store without creating import" do
    adapter = mock("vector_store_adapter")
    adapter.stubs(:supported_extensions).returns(%w[.csv .pdf])
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    family_document = family_documents(:tax_return)
    Family.any_instance.expects(:upload_document).with do |file_content:, filename:, **|
      assert_not_empty file_content
      assert_equal "valid.csv", filename
      true
    end.returns(family_document)

    assert_no_difference "Import.count" do
      post imports_url, params: {
        import: {
          type: "DocumentImport",
          import_file: file_fixture_upload("imports/valid.csv", "text/csv")
        }
      }
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.document_uploaded"), flash[:notice]
  end

  test "uploads pdf document as PdfImport when using DocumentImport option" do
    adapter = mock("vector_store_adapter")
    adapter.stubs(:supported_extensions).returns(%w[.pdf .txt])
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    @user.family.expects(:upload_document).never

    assert_difference "Import.count", 1 do
      post imports_url, params: {
        import: {
          type: "DocumentImport",
          import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf")
        }
      }
    end

    created_import = Import.order(:created_at).last
    assert_equal "PdfImport", created_import.type
    assert_redirected_to import_url(created_import)
    assert_equal I18n.t("imports.create.pdf_processing"), flash[:notice]
  end

  test "rejects unsupported document type for DocumentImport option" do
    adapter = mock("vector_store_adapter")
    adapter.stubs(:supported_extensions).returns(%w[.pdf .txt])
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    assert_no_difference "Import.count" do
      post imports_url, params: {
        import: {
          type: "DocumentImport",
          import_file: file_fixture_upload("profile_image.png", "image/png")
        }
      }
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.invalid_document_file_type"), flash[:alert]
  end

  test "publishes import" do
    import = imports(:transaction)

    TransactionImport.any_instance.expects(:publish_later).once

    post publish_import_url(import)

    assert_equal "Your import has started in the background.", flash[:notice]
    assert_redirected_to import_path(import)
  end

  test "destroys import" do
    import = imports(:transaction)

    assert_difference "Import.count", -1 do
      delete import_url(import)
    end

    assert_redirected_to imports_path
  end
end
