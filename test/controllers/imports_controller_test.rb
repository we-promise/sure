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

    assert_select "button[data-action='click->privacy-mode#toggle']", count: 1
    assert_select "[data-controller='bulk-select']"
    assert_select "[data-bulk-select-target='selectionBar']"
    assert_select "form#bulk-delete-form"
    assert_select "input[data-bulk-select-target='row'][form='bulk-delete-form']", count: @user.family.imports.where(type: Import::TYPES).count
    assert_select "#bulk-delete-form button[type='submit']"
    assert_select "input[data-bulk-select-target='row']", count: @user.family.imports.where(type: Import::TYPES).count

    @user.family.imports.ordered.each do |import|
      assert_select "#" + dom_id(import), count: 1
    end
  end

  test "shows PDF file names as privacy-sensitive values" do
    import = imports(:pdf_processed)
    import.pdf_file.attach(
      io: StringIO.new(file_fixture("imports/sample_bank_statement.pdf").binread),
      filename: "checking-january.pdf",
      content_type: "application/pdf"
    )

    get imports_url

    assert_response :success
    assert_select "##{dom_id(import)} span.privacy-sensitive", text: "checking-january.pdf"
  end

  test "gets new with an aggregate upload size warning" do
    adapter = mock("vector_store_adapter")
    adapter.stubs(:supported_extensions).returns(%w[.pdf .txt])
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    get new_import_url

    assert_response :success
    assert_select "turbo-frame#modal"
    assert_select "form[data-controller='batch-upload-warning']"
    assert_select "input[type='file'][data-action='change->batch-upload-warning#upload']"
  end

  test "cancel marks a lost import as failed" do
    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 2.hours.ago)

    post cancel_import_path(import)

    assert_redirected_to imports_path
    assert_equal "failed", import.reload.status
    assert_equal Import.lost_error_message, import.error
  end

  test "cancel refuses an import that is not presumed lost" do
    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 5.minutes.ago)

    post cancel_import_path(import)

    assert_equal I18n.t("imports.cancel.not_cancellable"), flash[:alert]
    assert_equal "importing", import.reload.status
  end

  test "cannot cancel another family's import" do
    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 2.hours.ago)

    sign_in users(:empty)

    post cancel_import_path(import)

    assert_response :not_found
    assert_equal "importing", import.reload.status
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

  test "uploads multiple documents independently" do
    adapter = mock("vector_store_adapter")
    adapter.stubs(:supported_extensions).returns(%w[.pdf .txt])
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    family_document = family_documents(:tax_return)
    Family.any_instance.expects(:upload_document).with do |file_content:, filename:, **|
      assert_equal "notes.txt", filename
      assert_equal "plain text", file_content
      true
    end.returns(family_document)

    valid_pdf = file_fixture_upload("imports/sample_bank_statement.pdf", "application/pdf")
    text_file = Rack::Test::UploadedFile.new(
      StringIO.new("plain text"),
      "text/plain",
      original_filename: "notes.txt"
    )

    assert_difference [ "AccountStatement.count", "Import.where(type: 'PdfImport').count" ], 1 do
      assert_enqueued_jobs 1, only: ProcessPdfJob do
        post imports_url, params: {
          import: {
            type: "DocumentImport",
            import_file: [ valid_pdf, text_file ]
          }
        }
      end
    end

    assert_redirected_to imports_url
    assert_equal "1 PDF is being processed. You will receive an email when analysis is complete. 1 document uploaded successfully.", flash[:notice]
  end

  test "summary renders the import outcome for a pdf import" do
    get summary_import_url(imports(:pdf_with_rows))

    assert_response :success
    assert_select "dialog"
  end

  test "summary is not available for non-pdf imports" do
    get summary_import_url(imports(:transaction))

    assert_response :not_found
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

  test "recognizes a PDF by extension with an unrecognized MIME type in a batch" do
    adapter = mock("vector_store_adapter")
    adapter.stubs(:supported_extensions).returns(%w[.pdf])
    VectorStore::Registry.stubs(:adapter).returns(adapter)
    source = file_fixture("imports/sample_bank_statement.pdf").binread
    files = ["first.pdf", "second.pdf"].each_with_index.map do |filename, index|
      uploaded_file(filename: filename, content_type: "application/octet-stream", content: source + "\n% copy #{index}")
    end

    assert_difference "Import.where(type: 'PdfImport').count", 2 do
      assert_enqueued_jobs 2, only: ProcessPdfJob do
        post imports_url, params: { import: { type: "DocumentImport", import_file: files } }
      end
    end
  end

  test "reports batch PDFs whose processing jobs could not be scheduled" do
    adapter = mock("vector_store_adapter")
    adapter.stubs(:supported_extensions).returns(%w[.pdf])
    VectorStore::Registry.stubs(:adapter).returns(adapter)
    PdfImport.any_instance.stubs(:process_with_ai_later).returns(false)
    source = file_fixture("imports/sample_bank_statement.pdf").binread
    files = ["first.pdf", "second.pdf"].each_with_index.map do |filename, index|
      uploaded_file(filename: filename, content_type: "application/pdf", content: source + "\n% copy #{index}")
    end

    assert_difference "Import.where(type: 'PdfImport').count", 2 do
      assert_no_enqueued_jobs only: ProcessPdfJob do
        post imports_url, params: { import: { type: "DocumentImport", import_file: files } }
      end
    end
    assert_equal %w[pending pending], PdfImport.order(:created_at).last(2).map(&:status)
    assert_includes flash[:alert], "first.pdf"
    assert_includes flash[:alert], "second.pdf"
  end

  test "reports filename when a vector-store upload returns nil" do
    adapter = mock("vector_store_adapter")
    adapter.stubs(:supported_extensions).returns(%w[.txt])
    VectorStore::Registry.stubs(:adapter).returns(adapter)
    Family.any_instance.expects(:upload_document).twice.returns(nil)

    post imports_url, params: { import: { type: "DocumentImport", import_file: [
      uploaded_file(filename: "first.txt", content_type: "text/plain", content: "first"),
      uploaded_file(filename: "second.txt", content_type: "text/plain", content: "second")
    ] } }

    assert_includes flash[:alert], "first.txt"
    assert_includes flash[:alert], "second.txt"
  end

  test "accepts document batches above the aggregate size warning" do
    files = (1..11).map do |index|
      uploaded_file(filename: "notes-#{index}.txt", content_type: "text/plain", content: "notes")
    end
    ActionDispatch::Http::UploadedFile.any_instance.stubs(:size).returns(10.megabytes)
    adapter = mock("vector_store_adapter")
    adapter.stubs(:supported_extensions).returns(%w[.txt])
    VectorStore::Registry.stubs(:adapter).returns(adapter)
    Family.any_instance.expects(:upload_document).times(files.size).returns("uploaded")

    post imports_url, params: { import: { type: "DocumentImport", import_file: files } }

    assert_equal I18n.t("imports.create.document_uploaded_many", count: files.size), flash[:notice]
    assert_nil flash[:alert]
  end

  test "bulk deletion rejects requests above the operation limit" do
    delete destroy_all_imports_url, params: { bulk_delete: { import_ids: Array.new(Import::MAX_BATCH_DELETE_IMPORTS + 1) { imports(:transaction).id } } }

    assert_equal I18n.t("imports.destroy_all.limit", count: Import::MAX_BATCH_DELETE_IMPORTS), flash[:alert]
    assert imports(:transaction).persisted?
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

  test "deletes a completed import with no committed data" do
    import = imports(:pdf_processed)

    assert_difference "Import.count", -1 do
      delete import_url(import)
    end

    assert_redirected_to imports_path
  end

  test "does not delete a completed import with committed data" do
    import = imports(:transaction)
    import.update!(status: :complete)
    entries(:transaction).update!(import: import)

    assert_no_difference "Import.count" do
      delete import_url(import)
    end

    assert_redirected_to imports_path
    assert_equal I18n.t("imports.destroy.not_deletable"), flash[:alert]
  end

  test "bulk deletes selected imports in the current family" do
    imports = [ imports(:transaction), imports(:trade) ]

    assert_difference "Import.count", -2 do
      delete destroy_all_imports_url, params: {
        bulk_delete: { import_ids: imports.map(&:id) }
      }
    end

    assert_redirected_to imports_path
    assert_equal "2 imports deleted.", flash[:notice]
  end

  test "bulk deletion skips completed imports with committed data" do
    import = imports(:transaction)
    import.update!(status: :complete)
    entries(:transaction).update!(import: import)

    assert_no_difference "Import.count" do
      delete destroy_all_imports_url, params: {
        bulk_delete: { import_ids: [ import.id ] }
      }
    end

    assert_redirected_to imports_path
    assert_equal I18n.t("imports.destroy_all.not_deletable", count: 1), flash[:alert]
  end

  test "bulk deletion is scoped to the current family" do
    other_family_import = Import.create!(family: families(:empty), type: "TransactionImport")

    assert_no_difference "Import.count" do
      delete destroy_all_imports_url, params: {
        bulk_delete: { import_ids: [ other_family_import.id ] }
      }
    end

    assert_redirected_to imports_path
    assert_equal "No deletable imports were selected.", flash[:alert]
  end

  test "respects SURE_IMPORT_MAX_NDJSON_SIZE_MB when creating Sure import (#3010)" do
    configured_limit = 2.megabytes
    SureImport.stubs(:max_ndjson_size).returns(configured_limit)

    oversized_file = Rack::Test::UploadedFile.new(
      StringIO.new("x" * (configured_limit + 1)),
      "application/x-ndjson",
      original_filename: "all.ndjson"
    )

    assert_no_difference "Import.count" do
      post imports_url, params: {
        import: {
          type: "SureImport",
          import_file: oversized_file
        }
      }
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.file_too_large", max_size: configured_limit / 1.megabyte), flash[:alert]
  end

  test "shows a friendly warning when a Sure import's transactions reference merchants missing from the export (#3113)" do
    import = @user.family.imports.create!(type: "SureImport")
    ndjson = [
      { type: "Account", data: {
        id: "account-1", name: "Old Export Checking", balance: "1000.00", currency: "USD",
        accountable_type: "Depository", accountable: { subtype: "checking" }
      } },
      { type: "Transaction", data: {
        id: "transaction-1", account_id: "account-1", merchant_id: "merchant-never-exported",
        date: "2024-01-15", amount: "42.50", name: "Amazon purchase", currency: "USD"
      } }
    ].map(&:to_json).join("\n")
    import.ndjson_file.attach(io: StringIO.new(ndjson), filename: "all.ndjson", content_type: "application/x-ndjson")
    import.sync_ndjson_rows_count!

    get import_url(import)

    assert_response :success
    assert_includes response.body, I18n.t("imports.ready.missing_merchant_warning_title")
  end

  test "does not show the missing merchant warning for a Sure import with no unresolved merchant references" do
    import = @user.family.imports.create!(type: "SureImport")
    ndjson = [
      { type: "Account", data: {
        id: "account-1", name: "Clean Export Checking", balance: "1000.00", currency: "USD",
        accountable_type: "Depository", accountable: { subtype: "checking" }
      } }
    ].map(&:to_json).join("\n")
    import.ndjson_file.attach(io: StringIO.new(ndjson), filename: "all.ndjson", content_type: "application/x-ndjson")
    import.sync_ndjson_rows_count!

    get import_url(import)

    assert_response :success
    assert_not_includes response.body, I18n.t("imports.ready.missing_merchant_warning_title")
  end

  test "explains that unnamed recurring transactions with a missing merchant will be skipped" do
    import = @user.family.imports.create!(type: "SureImport")
    ndjson = [
      { type: "Account", data: {
        id: "account-1", name: "Checking", balance: "1000.00", currency: "USD",
        accountable_type: "Depository", accountable: { subtype: "checking" }
      } },
      { type: "RecurringTransaction", data: {
        id: "recurring-1", account_id: "account-1", merchant_id: "merchant-never-exported",
        amount: "11.99", currency: "USD", expected_day_of_month: 28,
        last_occurrence_date: "2026-08-28", next_expected_date: "2026-09-28"
      } }
    ].map(&:to_json).join("\n")
    import.ndjson_file.attach(io: StringIO.new(ndjson), filename: "all.ndjson", content_type: "application/x-ndjson")
    import.sync_ndjson_rows_count!

    get import_url(import)

    assert_response :success
    assert_includes response.body, I18n.t("imports.ready.missing_merchant_warning_title")
    assert_includes response.body, I18n.t("imports.ready.skipped_recurring_description", count: 1).squish
    assert_not_includes response.body, "merchant reference in this file"
  end

  test "shows a friendly notice when a Sure import reuses existing categories, tags or merchants by name (#3113)" do
    @user.family.categories.create!(name: "Groceries", color: "#407706", lucide_icon: "shopping-basket")
    import = @user.family.imports.create!(type: "SureImport")
    ndjson = [
      { type: "Category", data: { id: "category-1", name: "Groceries" } }
    ].map(&:to_json).join("\n")
    import.ndjson_file.attach(io: StringIO.new(ndjson), filename: "all.ndjson", content_type: "application/x-ndjson")
    import.sync_ndjson_rows_count!

    get import_url(import)

    assert_response :success
    assert_includes response.body, I18n.t("imports.ready.reused_taxonomy_notice_title")
  end

  test "does not show the reused taxonomy notice for a Sure import with no name collisions" do
    import = @user.family.imports.create!(type: "SureImport")
    ndjson = [
      { type: "Category", data: { id: "category-1", name: "A Brand New Category Name" } }
    ].map(&:to_json).join("\n")
    import.ndjson_file.attach(io: StringIO.new(ndjson), filename: "all.ndjson", content_type: "application/x-ndjson")
    import.sync_ndjson_rows_count!

    get import_url(import)

    assert_response :success
    assert_not_includes response.body, I18n.t("imports.ready.reused_taxonomy_notice_title")
  end

  test "shows the differences when an existing provider merchant differs from the Sure import file" do
    ProviderMerchant.create!(name: "AMZN MKTP", source: "plaid", website_url: "https://amazon.com")
    import = @user.family.imports.create!(type: "SureImport")
    ndjson = [
      { type: "Account", data: {
        id: "account-1", name: "Checking", balance: "1000.00", currency: "USD",
        accountable_type: "Depository", accountable: { subtype: "checking" }
      } },
      { type: "ProviderMerchant", data: { id: "pm-1", name: "AMZN MKTP", source: "plaid", website_url: "https://amazon.co.uk" } }
    ].map(&:to_json).join("\n")
    import.ndjson_file.attach(io: StringIO.new(ndjson), filename: "all.ndjson", content_type: "application/x-ndjson")
    import.sync_ndjson_rows_count!

    get import_url(import)

    assert_response :success
    assert_includes response.body, I18n.t("imports.ready.provider_merchant_diff_title")
    assert_includes response.body, "AMZN MKTP"
    assert_includes response.body, "keeping https://amazon.com, file has https://amazon.co.uk"
  end

  test "does not show the provider merchant differences notice without a difference" do
    import = @user.family.imports.create!(type: "SureImport")
    ndjson = [
      { type: "Account", data: {
        id: "account-1", name: "Checking", balance: "1000.00", currency: "USD",
        accountable_type: "Depository", accountable: { subtype: "checking" }
      } }
    ].map(&:to_json).join("\n")
    import.ndjson_file.attach(io: StringIO.new(ndjson), filename: "all.ndjson", content_type: "application/x-ndjson")
    import.sync_ndjson_rows_count!

    get import_url(import)

    assert_response :success
    assert_not_includes response.body, I18n.t("imports.ready.provider_merchant_diff_title")
  end

  test "import ready notices use singular and plural wording" do
    {
      "imports.ready.missing_merchant_warning_description" => [ "1 merchant reference in this file", "2 merchant references in this file" ],
      "imports.ready.reused_taxonomy_notice_description" => [ "1 category, tag or merchant", "2 categories, tags or merchants" ],
      "imports.ready.provider_merchant_diff_description" => [ "1 merchant in this file", "2 merchants in this file" ]
    }.each do |key, (singular, plural)|
      assert_includes I18n.t(key, count: 1), singular
      assert_includes I18n.t(key, count: 2), plural
    end
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
