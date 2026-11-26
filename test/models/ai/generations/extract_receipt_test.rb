require "test_helper"

class Ai::Generations::ExtractReceiptTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    use_ai_routes
  end

  def generation(files: [ photo ], category_names: [ "Food & Drink", "Household" ])
    Ai::Generations::ExtractReceipt.new(files:, category_names:, family: @family, user: @user)
  end

  def photo = Ai::Attachment.new(filename: "receipt.jpg", content_type: "image/jpeg", data: file_fixture("receipts/rotated.jpg").binread)

  def pdf = Ai::Attachment.pdf(file_fixture("receipts/receipt.pdf").binread, filename: "receipt.pdf")

  test "a category name is matched to the family's spelling, and an unknown one is dropped" do
    value = generation.coerce(receipt_ai_answer(line_items: [
      { name: "Cheese", quantity: 1, amount: 30.0, discount: 0, category_name: "food & drink" },
      { name: "Soap", quantity: 1, amount: 20.0, discount: 0, category_name: "Cleaning" }
    ]).deep_stringify_keys)

    assert_equal [ "Food & Drink", nil ], value[:line_items].map { _1[:category_name] }
  end

  test "a PDF is sent as its page images, a photo as it is" do
    attachments = generation(files: [ pdf ]).attachments

    assert attachments.any?
    assert attachments.all?(&:image?)
    assert_equal [ photo ], generation.attachments
  end

  test "is sent only to a model that reads images" do
    use_ai_routes(extract_receipt: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    requests = stub_ai(:extract_receipt, returns: receipt_ai_answer)

    result = generation.call

    assert result.success?
    assert_equal [ "gpt-4.1-mini" ], requests.map { _1.model.name }
  end

  test "no model that reads images leaves the receipt unread" do
    use_ai_routes(extract_receipt: %w[gpu/qwen3-8b])
    requests = stub_ai(:extract_receipt, returns: receipt_ai_answer)

    assert generation.call.unavailable?
    assert_empty requests
  end
end
