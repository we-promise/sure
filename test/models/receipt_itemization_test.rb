require "test_helper"

class ReceiptItemizationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    use_ai_routes(extract_receipt: %w[openai/gpt-4.1-mini])
    @entry = create_transaction(account: accounts(:depository), amount: 100)
    @transaction = @entry.transaction
    @transaction.attachments.attach(io: StringIO.new("png"), filename: "receipt.png", content_type: "image/png")
  end

  test "job saves a review-only result and broadcasts a frame reload" do
    request = ReceiptItemization.start!(transaction: @transaction, user: @user)
    stub_ai { { merchant_name: "Store", currency: "USD", line_items: [ { name: "Food", amount: 90 } ], tax: 10, discount: nil, total: 100 } }
    Turbo::StreamsChannel.expects(:broadcast_action_to).with(request, has_entries(action: :replace, target: "modal", partial: "splits/receipt_result"))
    Ai::GenerationJob.perform_now(:extract_receipt, { id: request.id })
    assert_equal "completed", request.reload.status
    assert_equal "100.0", request.proposal.dig("split", "splits", 0, "amount")
    refute @entry.reload.split_parent?
  end

  test "consent revoked before execution prevents the model call" do
    request = ReceiptItemization.start!(transaction: @transaction, user: @user)
    @user.update!(ai_enabled: false)
    Ai::Generations::ExtractReceipt.expects(:new).never
    Ai::GenerationJob.perform_now(:extract_receipt, { id: request.id })
    assert_equal "failed", request.reload.status
  end

  test "consent revoked while a model call is running prevents storing its answer" do
    request = ReceiptItemization.start!(transaction: @transaction, user: @user)
    request.ai_generation
    User.find(@user.id).update!(ai_enabled: false)
    assert_raises(Ai::Error::Cancelled) do
      request.apply_ai(Ai::Result.new(value: { line_items: [] }))
    end
    assert_empty request.reload.proposal
  end

  test "missing storage fails privately without persisting receipt content" do
    request = ReceiptItemization.start!(transaction: @transaction, user: @user)
    ActiveStorage::Attachment.any_instance.stubs(:download).raises(ActiveStorage::FileNotFoundError, "private receipt text")
    Ai::GenerationJob.perform_now(:extract_receipt, { id: request.id })
    assert_equal "failed", request.reload.status
    assert_empty request.proposal
    log = DebugLogEntry.where(category: "receipt_itemization").recent.first
    assert_no_match "private receipt text", log.message
  end

  test "a job for a deleted attachment is discarded" do
    request = ReceiptItemization.start!(transaction: @transaction, user: @user)
    @transaction.attachments.first.destroy!
    Ai::Generations::ExtractReceipt.expects(:new).never
    assert_nothing_raised { Ai::GenerationJob.perform_now(:extract_receipt, { id: request.id }) }
  end

  test "rejects an attachment from a different transaction" do
    other = create_transaction(account: accounts(:depository), amount: 10).transaction
    assert_raises(Transaction::ReceiptItemizer::Error) do
      ReceiptItemization.start!(transaction: other, user: @user, attachment_id: @transaction.attachments.first.id)
    end
  end

  test "enqueue failure leaves a terminal result instead of pending forever" do
    Ai::GenerationJob.stubs(:perform_later).returns(false)
    request = ReceiptItemization.start!(transaction: @transaction, user: @user)
    assert_equal "failed", request.status
  end
end
