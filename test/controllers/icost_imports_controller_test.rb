require "test_helper"

class IcostImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    ensure_tailwind_build
  end

  test "iCost requests never auto-sync a family even when auto-sync is due" do
    batch = prepare_sample
    record = batch.records.first
    [ IcostImportsController, IcostRecordsController ].each do |controller|
      controller.any_instance.stubs(:family_needs_auto_sync?).returns(true)
      controller.any_instance.expects(:sync_family).never
    end
    Family.any_instance.expects(:request_plaid_transactions_refreshes_later).never
    Family.any_instance.expects(:sync_later).never

    [ icost_imports_path, new_icost_import_path, icost_import_path(batch),
      icost_import_record_path(batch, record) ].each do |path|
      get path
      assert_response :success
      assert_select "[data-icost-page].ph-no-capture.privacy-sensitive", count: 1
    end
    post icost_imports_path, params: { icost_import: { file: sample_file } }
    assert_redirected_to icost_import_path(batch)
    patch icost_import_record_path(batch, record), params: { resolution: { review_note: "Local-only synthetic review" } }
    assert_redirected_to icost_import_record_path(batch, record)
    post publish_icost_import_path(batch)
    assert_redirected_to icost_import_path(batch)
  end

  test "upload stages an original file and a repeated upload reopens it" do
    assert_difference "IcostImport.count", 1 do
      post icost_imports_path, params: { icost_import: { file: sample_file } }
    end
    batch = @user.family.icost_imports.last
    assert_redirected_to icost_import_path(batch)
    assert_equal 1, batch.records.count

    assert_no_difference "IcostImport.count" do
      assert_no_difference "Entry.count" do
        post icost_imports_path, params: { icost_import: { file: sample_file } }
      end
    end
    assert_redirected_to icost_import_path(batch)
    get icost_import_path(batch)
    assert_response :success
    assert_select "[data-icost-count]", count: 5
  end

  test "index and upload form provide a discoverable local import flow" do
    batch = prepare_sample
    get icost_imports_path
    assert_response :success
    assert_select "a[href=?]", icost_import_path(batch)
    assert_select "a[href=?]", new_icost_import_path
    get new_icost_import_path
    assert_response :success
    assert_select "form[enctype='multipart/form-data'] input[type=file][accept='.csv,.xlsx']"
  end

  test "native transaction and transfer drawers display structured source details" do
    batch = prepare_sample
    record = batch.records.first
    record.update!(entry: entries(:transaction), status: "published")
    get transaction_path(entries(:transaction)), headers: { "Turbo-Frame" => "drawer" }
    assert_response :success
    assert_select "[data-icost-details]", count: 1
    assert_select "[data-icost-location]", text: /Synthetic place/

    record.update!(entry: entries(:transfer_out), counterpart_entry: entries(:transfer_in))
    get transfer_path(transfers(:one)), headers: { "Turbo-Frame" => "drawer" }
    assert_response :success
    assert_select "[data-icost-details]", count: 1
    assert_select "[data-icost-location]", text: /Unknown/
  end

  test "missing or malformed uploads do not create a batch" do
    assert_no_difference "IcostImport.count" do
      post icost_imports_path, params: { icost_import: {} }
      assert_redirected_to new_icost_import_path
      post icost_imports_path, params: { icost_import: { file: uploaded_file(filename: "bad.xlsx", content_type: "application/octet-stream", content: "not a workbook") } }
      assert_redirected_to new_icost_import_path
    end
  end

  test "multiple uploads keep valid files when another file cannot be parsed" do
    assert_difference "IcostImport.count", 1 do
      post icost_imports_path, params: { icost_import: { files: [ sample_file,
        uploaded_file(filename: "bad.xlsx", content_type: "application/octet-stream", content: "not a workbook") ] } }
    end
    assert_redirected_to icost_imports_path
    assert flash[:alert].present?
    assert flash[:notice].present?
  end

  test "XLSX uploads can queue automatic posting and replay the same archive" do
    assert_enqueued_jobs 1, only: IcostPublishJob do
      assert_difference "IcostImport.count", 1 do
        post icost_imports_path, params: { icost_import: { files: [ file_fixture_upload("imports/icost.xlsx") ], auto_post: "1" } }
      end
    end
    batch = @user.family.icost_imports.last
    assert_redirected_to icost_import_path(batch)
    assert_equal "Synthetic museum", batch.records.sole.location_text
    assert_no_difference [ "IcostImport.count", "Entry.count" ] do
      post icost_imports_path, params: { icost_import: { files: [ file_fixture_upload("imports/icost.xlsx") ] } }
    end
    assert_redirected_to icost_import_path(batch)
  end

  test "upload posts normal records by default and makes them visible in transactions" do
    Balance::Materializer.any_instance.stubs(:materialize_balances)
    session = @user.sessions.order(:created_at).last
    session.update!(prev_transaction_page_params: { q: { account_ids: [ SecureRandom.uuid ], end_date: "1901-01-02" }, page: 4 })
    assert_difference "Entry.count", 1 do
      perform_enqueued_jobs(only: IcostPublishJob) do
        post icost_imports_path, params: { icost_import: { files: [ file_fixture_upload("imports/icost.xlsx") ] } }
      end
    end
    batch = @user.family.icost_imports.last
    assert_equal "published", batch.records.sole.status
    assert_empty session.reload.prev_transaction_page_params.fetch("q")
    get transactions_path
    follow_redirect! if response.redirect?
    assert_response :success
    assert_includes response.body, "iCost R0002"
  end

  test "preview reports missing ledger links instead of a successful recorded count" do
    batch = prepare_sample
    batch.records.sole.update!(status: "published")
    get icost_import_path(batch)
    assert_response :success
    assert_select "[data-icost-count='entry_missing']", text: /1/
    assert_select "[data-icost-count='published']", text: /0/
    assert_includes response.body, I18n.t("icost_imports.statuses.entry_missing")
  end

  test "explicit preview-only uploads do not queue posting or reset transaction filters" do
    session = @user.sessions.order(:created_at).last
    session.update!(prev_transaction_page_params: { q: { search: "Keep this filter" } })
    assert_no_enqueued_jobs only: IcostPublishJob do
      post icost_imports_path, params: { icost_import: { files: [ file_fixture_upload("imports/icost.xlsx") ], auto_post: "0" } }
    end
    assert_equal "Keep this filter", session.reload.prev_transaction_page_params.dig("q", "search")
  end

  test "batch account form submits indexed mappings through the owner scope" do
    batch = prepare_sample
    patch resolve_accounts_icost_import_path(batch), params: { account_mappings: { mappings: {
      "0" => { source_account: "", currency: "USD", account_id: accounts(:depository).id }
    } } }
    assert_redirected_to icost_import_path(batch)
    assert_equal accounts(:depository).id, batch.records.sole.resolution["account_id"]
  end

  test "parser failures show a useful reason on the upload page" do
    post icost_imports_path, params: { icost_import: { file: uploaded_file(filename: "bad.xls", content_type: "application/octet-stream", content: "synthetic") } }
    assert_redirected_to new_icost_import_path
    assert_includes flash[:alert], I18n.t("icost_imports.parse_errors.unsupported_file_type")
    follow_redirect!
    assert_response :success
    assert_select "[data-icost-upload-errors]", count: 1
  end

  test "batch access is isolated from another user in the same family and other families" do
    batch = prepare_sample
    [ users(:family_member), users(:empty) ].each do |other_user|
      sign_in other_user
      get icost_import_path(batch)
      assert_response :not_found
      post publish_icost_import_path(batch)
      assert_response :not_found
      get icost_import_record_path(batch, batch.records.first)
      assert_response :not_found
    end
  end

  test "guests cannot upload or open the upload form" do
    sign_in family_guest
    get new_icost_import_path
    assert_response :forbidden
    assert_no_difference "IcostImport.count" do
      post icost_imports_path, params: { icost_import: { file: sample_file } }
    end
    assert_response :forbidden
  end

  test "raw fields and local coordinates are escaped without network elements" do
    batch = prepare_sample
    get icost_import_record_path(batch, batch.records.first)
    assert_response :success
    assert_select "[data-icost-raw-fields]", text: /Future field/
    assert_select "[data-icost-details] script, [data-icost-details] iframe, [data-icost-details] img", count: 0
    assert_select "[data-icost-details] a[href^='http']", count: 0
    assert_select "[data-icost-location]", text: /31.2304/
    assert_select "[data-icost-location]", text: /121.4737/
    assert_select "[data-icost-location]", text: /Unknown/
    assert_includes response.body, "&lt;script&gt;synthetic&lt;/script&gt;"
  end

  test "account review keeps the selected account visible after valuation review or readiness" do
    batch = prepare_sample
    record = batch.records.first
    account = accounts(:depository)
    record.update!(resolution: { "account_id" => account.id }, issues: [ "account_valuation_requires_review" ])
    get icost_import_record_path(batch, record)
    assert_response :success
    assert_select "select#resolution_account_id option[selected][value=?]", account.id, text: account.name
    assert_select "select#resolution_from_account_id", count: 0

    record.update!(status: "ready", issues: [])
    get icost_import_record_path(batch, record)
    assert_response :success
    assert_select "select#resolution_account_id option[selected][value=?]", account.id, text: account.name
  end

  test "transfer review shows only explicit direction fields and retains selected account names" do
    batch = IcostImport.prepare!(family: @user.family, user: @user,
                                 bytes: sample_csv.sub(",支出,", ",转账,"), filename: "synthetic-transfer.csv")
    record = batch.records.first
    from = accounts(:depository)
    to = accounts(:other_asset)
    record.update!(resolution: { "from_account_id" => from.id, "to_account_id" => to.id },
                   issues: [ "account_required", "account_valuation_requires_review" ])
    get icost_import_record_path(batch, record)
    assert_response :success
    assert_select "select#resolution_account_id", count: 0
    assert_select "select#resolution_from_account_id option[selected][value=?]", from.id, text: from.name
    assert_select "select#resolution_to_account_id option[selected][value=?]", to.id, text: to.name

    record.update!(issues: [ "installment_details_required" ])
    get icost_import_record_path(batch, record)
    assert_response :success
    assert_select "select#resolution_from_account_id, select#resolution_to_account_id", count: 0
  end

  test "review only accepts explicit resolution fields" do
    batch = prepare_sample
    record = batch.records.first
    previous = record.attributes.slice("amount", "status", "raw_fields")
    patch icost_import_record_path(batch, record), params: {
      resolution: { review_note: "Synthetic review", amount: "999999", status: "published", raw_fields: { note: "changed" } }
    }
    assert_redirected_to icost_import_record_path(batch, record)
    assert_equal "Synthetic review", record.reload.review_note
    assert_equal previous, record.attributes.slice("amount", "status", "raw_fields")
  end

  private
    def sample_csv
      CSV.generate do |csv|
        csv << %w[日期 类型 金额 一级分类 二级分类 账户1 账户2 备注 货币 标签 账本 位置 退款 优惠 手续费 图片链接1 图片链接2 图片链接3 图片附件1 图片附件2 图片附件3 纬度 经度] + [ "Future field" ]
        csv << [ "2026/01/02 03:04:05", "支出", "-12.34", "Synthetic category", "", "", "", "<script>synthetic</script>", "USD", "#Synthetic", "Synthetic ledger", "Synthetic place", "0", "0", "0", "https://example.invalid/private-image", "", "", "", "", "", "31.2304", "121.4737", "preserve me" ]
      end
    end

    def sample_file
      uploaded_file(filename: "synthetic-icost.csv", content_type: "text/csv", content: sample_csv)
    end

    def prepare_sample
      IcostImport.prepare!(family: @user.family, user: @user, bytes: sample_csv, filename: "synthetic-icost.csv")
    end
end
