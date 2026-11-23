require "test_helper"

class ReceiptScansControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
    use_ai_routes
    Provider::Registry.stubs(:preferred_llm_provider).returns(stub(supports_receipt_extraction?: true))
  end

  test "redirects when the configured AI provider cannot read receipts" do
    set_preview(true)
    Provider::Registry.stubs(:preferred_llm_provider).returns(stub(supports_receipt_extraction?: false))

    get new_receipt_scan_url

    assert_redirected_to root_path
  end

  test "transactions page hides receipt scanning when the AI provider cannot read receipts" do
    set_preview(true)
    Provider::Registry.stubs(:preferred_llm_provider).returns(stub(supports_receipt_extraction?: false))

    get transactions_url

    assert_select "a[href='#{new_receipt_scan_path}']", count: 0
  end

  test "redirects without preview" do
    set_preview(false)

    get new_receipt_scan_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "renders the upload form with preview" do
    set_preview(true)

    get new_receipt_scan_url

    assert_response :success
    assert_select "input[type=file][name='receipt_scan[files][]'][multiple]"
    assert_select "select[name='receipt_scan[account_id]'] option[value='#{@account.id}']"
  end

  test "creates and redirects to transaction" do
    set_preview(true)

    assert_difference "ReceiptScan.count", 1 do
      post receipt_scans_url, params: { receipt_scan: { account_id: @account.id, files: [ receipt_upload ] } }
    end

    scan = ReceiptScan.order(:created_at).last
    assert_redirected_to transactions_path
    assert_equal I18n.t("receipt_scans.create.success"), flash[:notice]
    assert_equal @user, scan.user
  end

  test "rejects foreign account" do
    set_preview(true)
    other = families(:empty).accounts.create!(name: "X", balance: 0, currency: "USD", accountable: Depository.new, owner: users(:empty))

    assert_no_difference "ReceiptScan.count" do
      post receipt_scans_url, params: { receipt_scan: { account_id: other.id, files: [ receipt_upload ] } }
    end

    assert_response :unprocessable_entity
  end

  test "shows the upload error" do
    set_preview(true)

    post receipt_scans_url, params: { receipt_scan: { account_id: @account.id, files: Array.new(6) { receipt_upload } } }

    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("receipt_scans.errors.too_many_files", count: ReceiptScan::MAX_FILES)
  end

  test "transaction page shows the receipt panel" do
    set_preview(true)
    entry = entries(:transaction)
    entry.entryable.update!(extra: { "receipt" => {
      "status" => "needs_review", "merchant" => "Corner Grocer", "nip" => "5260250274",
      "review_reasons" => [ { "reason" => "items_total_mismatch", "items_total" => "45.0", "total" => "50.0" } ],
      "line_items" => [ { "name" => "Cheese", "amount" => "30.00", "discount" => "0", "category_name" => "Food & Drink" } ],
      "vat_breakdown" => []
    } })

    get transaction_url(entry)

    assert_response :success
    assert_includes response.body, "Corner Grocer"
    assert_includes response.body, "Cheese"
    assert_includes response.body, I18n.t("transactions.receipt.status.needs_review")
    assert_includes response.body, ERB::Util.html_escape(I18n.t("transactions.receipt.reasons.items_total_mismatch"))
  end

  test "transactions page links to receipt scanning for preview users" do
    set_preview(true)

    get transactions_url

    assert_select "a[href='#{new_receipt_scan_path}']"
  end

  test "transactions page hides receipt scanning without preview" do
    set_preview(false)

    get transactions_url

    assert_select "a[href='#{new_receipt_scan_path}']", count: 0
  end

  private
    def set_preview(enabled)
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => enabled))
    end

    def receipt_upload
      fixture_file_upload("receipts/rotated.jpg", "image/jpeg")
    end
end
