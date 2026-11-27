require "test_helper"

class Ai::Generations::ExtractReceiptTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    use_ai_routes(extract_receipt: %w[openai/gpt-4.1-mini])
  end

  test "uses an inline image and the receipt feature" do
    attachment = stub(filename: "receipt.png", content_type: "image/png", download: "image bytes")
    generation = Ai::Generations::ExtractReceipt.new(attachment:, family: @user.family, user: @user)
    assert_equal [ :vision ], generation.needs
    assert_equal "image bytes", generation.attachments.first.data
    assert_equal :extract_receipt, generation.feature_key
  end

  test "text PDFs are read without requiring vision" do
    attachment = stub(filename: "receipt.pdf", content_type: "application/pdf", download: "pdf bytes")
    Pdf::TextExtractor.expects(:pages).with("pdf bytes").returns([ "Food 10.00" ])
    generation = Ai::Generations::ExtractReceipt.new(attachment:, family: @user.family, user: @user)
    assert_empty generation.attachments
    assert_equal "Food 10.00", generation.prompt_locals[:text]
  end

  test "scanned PDFs use the stack's document attachment" do
    attachment = stub(filename: "receipt.pdf", content_type: "application/pdf", download: "pdf bytes")
    Pdf::TextExtractor.expects(:pages).with("pdf bytes").returns([ "" ])
    generation = Ai::Generations::ExtractReceipt.new(attachment:, family: @user.family, user: @user)
    assert_equal [ :documents ], generation.needs
    assert generation.attachments.first.pdf?
  end
end
