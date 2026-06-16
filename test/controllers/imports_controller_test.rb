require "test_helper"

class ImportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in @user = users(:family_admin)
    ensure_tailwind_build
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
    assert_select "button", text: "Import from Mint", count: 1
    assert_select "button", text: "Import from Actual Budget", count: 1
    assert_select "button", text: "Import from Quicken (QIF)", count: 1
    assert_select "button", text: "Import from YNAB", count: 1
    assert_select "span", text: "Import accounts first to unlock this option.", count: 2
    assert_select "div[aria-disabled=true]", count: 2
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
      assert_difference "AccountStatement.count", 1 do
        post imports_url, params: {
          import: {
            type: "DocumentImport",
            import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf")
          }
        }
      end
    end

    created_import = Import.order(:created_at).last
    assert_equal "PdfImport", created_import.type
    assert_equal AccountStatement.order(:created_at).last, created_import.account_statement
    assert_not created_import.pdf_file.attached?
    assert_redirected_to import_url(created_import)
    assert_equal I18n.t("imports.create.pdf_processing"), flash[:notice]
  end

  test "uploads pdf import through account statement" do
    assert_difference "AccountStatement.count", 1 do
      assert_difference "Import.where(type: 'PdfImport').count", 1 do
        post imports_url, params: {
          import: {
            import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf")
          }
        }
      end
    end

    statement = AccountStatement.order(:created_at).last
    created_import = PdfImport.order(:created_at).last
    assert_equal statement, created_import.account_statement
    assert_not created_import.pdf_file.attached?
    assert_redirected_to import_url(created_import)
    assert_equal I18n.t("imports.create.pdf_processing"), flash[:notice]
  end

  test "guest cannot create statement backed pdf import" do
    sign_in users(:intro_user)

    assert_no_difference [ "AccountStatement.count", "Import.where(type: 'PdfImport').count" ] do
      assert_no_enqueued_jobs only: ProcessPdfJob do
        post imports_url, params: {
          import: {
            import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf")
          }
        }
      end
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "duplicate pdf import reuses account statement" do
    statement = AccountStatement.create_from_upload!(
      family: @user.family,
      account: nil,
      file: uploaded_file(
        filename: "existing_statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )

    assert_no_difference "AccountStatement.count" do
      assert_difference "Import.where(type: 'PdfImport').count", 1 do
        post imports_url, params: {
          import: {
            import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf")
          }
        }
      end
    end

    created_import = PdfImport.order(:created_at).last
    assert_equal statement, created_import.account_statement
    assert_redirected_to import_url(created_import)
  end

  test "duplicate pdf import does not enqueue processing twice for reused import" do
    assert_difference "AccountStatement.count", 1 do
      assert_difference "Import.where(type: 'PdfImport').count", 1 do
        assert_enqueued_jobs 1, only: ProcessPdfJob do
          post imports_url, params: {
            import: {
              import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf")
            }
          }

          post imports_url, params: {
            import: {
              import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf")
            }
          }
        end
      end
    end

    created_import = PdfImport.order(:created_at).last
    assert_equal "importing", created_import.status
    assert_redirected_to import_url(created_import)
  end

  test "duplicate pdf import for inaccessible statement does not create import" do
    AccountStatement.create_from_upload!(
      family: @user.family,
      account: accounts(:investment),
      file: uploaded_file(
        filename: "existing_statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )

    sign_in users(:family_member)

    assert_no_difference [ "AccountStatement.count", "Import.where(type: 'PdfImport').count" ] do
      post imports_url, params: {
        import: {
          import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf")
        }
      }
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.duplicate_pdf_unavailable"), flash[:alert]
  end

  test "read only shared user cannot reuse duplicate statement backed pdf import" do
    AccountStatement.create_from_upload!(
      family: @user.family,
      account: accounts(:credit_card),
      file: uploaded_file(
        filename: "existing_statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )

    sign_in users(:family_member)

    assert_no_difference [ "AccountStatement.count", "Import.where(type: 'PdfImport').count" ] do
      assert_no_enqueued_jobs only: ProcessPdfJob do
        post imports_url, params: {
          import: {
            import_file: file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf")
          }
        }
      end
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.duplicate_pdf_unavailable"), flash[:alert]
  end

  test "setting statement backed pdf import account links source statement" do
    statement = AccountStatement.create_from_upload!(
      family: @user.family,
      account: nil,
      file: uploaded_file(
        filename: "statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )
    pdf_import = PdfImport.create_from_statement!(statement: statement)
    account = accounts(:depository)

    patch import_url(pdf_import), params: { import: { account_id: account.id } }

    assert_redirected_to import_url(pdf_import)
    assert_equal I18n.t("imports.update.account_saved", default: "Account saved."), flash[:notice]
    assert_equal account, pdf_import.reload.account
    assert_equal account, statement.reload.account
  end

  test "read only shared user cannot link source statement through pdf import account update" do
    account = accounts(:credit_card)
    statement = AccountStatement.create_from_upload!(
      family: @user.family,
      account: nil,
      file: uploaded_file(
        filename: "statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )
    pdf_import = PdfImport.create_from_statement!(statement: statement)

    sign_in users(:family_member)
    patch import_url(pdf_import), params: { import: { account_id: account.id } }

    assert_redirected_to account_url(account)
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert_nil pdf_import.reload.account
    assert_nil statement.reload.account
  end

  test "user cannot view statement backed pdf import for inaccessible statement" do
    statement = AccountStatement.create_from_upload!(
      family: @user.family,
      account: accounts(:investment),
      file: uploaded_file(
        filename: "statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )
    pdf_import = PdfImport.create_from_statement!(statement: statement)

    sign_in users(:family_member)
    get import_url(pdf_import)

    assert_response :not_found
  end

  test "read only shared user cannot publish statement backed pdf import" do
    account = accounts(:credit_card)
    statement = AccountStatement.create_from_upload!(
      family: @user.family,
      account: account,
      file: uploaded_file(
        filename: "statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )
    pdf_import = PdfImport.create_from_statement!(statement: statement)
    PdfImport.any_instance.expects(:publish_later).never

    sign_in users(:family_member)
    post publish_import_url(pdf_import)

    assert_redirected_to account_url(account)
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
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

  test "PDF import account select does not leak unshared family accounts (#1803)" do
    sign_in users(:family_member)
    pdf_import = imports(:pdf_with_rows)
    # The fixture has no attached pdf_file and no statement, so
    # ImportsController#show would redirect to the upload page. The
    # partial under test only renders for an uploaded PDF — stub the
    # state so we exercise the actual account-select scoping path.
    PdfImport.any_instance.stubs(:pdf_uploaded?).returns(true)

    get import_url(pdf_import)

    assert_response :success
    assert_select 'select[name="import[account_id]"] option', text: "Checking Account"
    assert_select 'select[name="import[account_id]"] option', text: "Collectable Account", count: 0
    assert_select 'select[name="import[account_id]"] option', text: "IOU (personal debt to friend)", count: 0
    assert_select 'select[name="import[account_id]"] option', text: "Plaid Depository Account", count: 0
  end
end
