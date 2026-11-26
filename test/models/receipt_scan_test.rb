require "test_helper"

class ReceiptScanTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "receipts are read only by a routed model that reads images" do
    use_ai_routes(extract_receipt: %w[gpu/qwen3-8b])
    assert_not ReceiptScan.extraction_available?(family: @family, user: @user)

    use_ai_routes(extract_receipt: %w[openai/gpt-4.1-mini])
    assert ReceiptScan.extraction_available?(family: @family, user: @user)
  end

  test "receipts aren't read for a member who turned AI off" do
    use_ai_routes
    @user.update!(ai_enabled: false)

    assert_not ReceiptScan.extraction_available?(family: @family, user: @user)
  end

  test "deleting the transaction deletes its receipt and the receipt's files" do
    scan = upload
    blob_ids = scan.files.map(&:blob_id)

    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { scan.linked_transaction.entry.destroy! }

    assert_not ReceiptScan.exists?(scan.id)
    assert_not ActiveStorage::Blob.exists?(id: blob_ids)
  end

  test "deleting the receipt's file from its transaction deletes the file" do
    scan = upload
    transaction = scan.linked_transaction
    attachment = transaction.attachments.first

    transaction.purge_attachment(attachment)

    assert_not ActiveStorage::Blob.exists?(attachment.blob_id)
    assert_empty scan.reload.files
  end

  test "a receipt whose file is still attached elsewhere leaves the file" do
    scan = upload
    other = Entry.create!(account: @account, name: "Other", date: Date.current, amount: 1, currency: "USD", entryable: Transaction.new)
    other.entryable.attachments.attach(scan.files.blobs)
    blob_ids = scan.files.map(&:blob_id)

    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { scan.destroy! }

    assert_equal blob_ids.size, ActiveStorage::Blob.where(id: blob_ids).count
  end

  test "account must belong to the family" do
    scan = ReceiptScan.new(family: families(:empty), user: @user, account: @account)

    assert_not scan.valid?
    assert scan.errors.of_kind?(:account, :invalid)
  end

  test "a scan outlives the member who uploaded it" do
    member = users(:family_member)
    scan = ReceiptScan.create!(family: @family, user: member, account: @account)

    member.destroy!

    assert_nil scan.reload.user
    assert_equal @account, scan.account
  end

  test "starts processing" do
    scan = ReceiptScan.create!(family: @family, user: @user, account: @account)

    assert scan.processing?
    assert_equal [], scan.review_reasons
  end

  test "flag! records the reason and marks the scan for review" do
    scan = receipt_scans(:processing)

    scan.flag!(:total_mismatch, expected: "10.00")

    assert scan.reload.needs_review?
    assert_equal [ { "reason" => "total_mismatch", "expected" => "10.00" } ], scan.review_reasons
  end

  test "destroying the account destroys its receipt scans" do
    scan = receipt_scans(:processing)

    scan.account.destroy!

    assert_not ReceiptScan.exists?(scan.id)
  end

  test "from_receipt? reads the transaction's extra" do
    transaction = transactions(:one)
    assert_not transaction.from_receipt?

    transaction.update!(extra: { "receipt" => { "status" => "processing" } })

    assert transaction.from_receipt?
  end

  private
    def upload
      use_ai_routes
      ReceiptScan.create_from_upload!(family: @family, user: @user, account: @account,
                                       uploads: [ Rack::Test::UploadedFile.new(file_fixture("receipts/rotated.jpg"), "image/jpeg") ])
    end
end
