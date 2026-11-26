require "test_helper"

class Ai::Generations::ExtractPurchaseTest < ActiveSupport::TestCase
  include PurchaseTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    use_ai_routes
  end

  def generation(files: [])
    Ai::Generations::ExtractPurchase.new(text: "Order #1, total 249.99", files:, category_names: [ "Food & Drink" ], family: @family, user: @user)
  end

  test "an email without files is read by a model that can't read images" do
    use_ai_routes(extract_purchase: %w[gpu/qwen3-8b])
    requests = stub_ai(:extract_purchase, returns: purchase_ai_answer)

    assert generation.call.success?
    assert_equal [ "qwen3-8b" ], requests.map { _1.model.name }
  end

  test "files are sent as images named after their number" do
    pdf = Ai::Attachment.pdf(build_pdf(pages: 2), filename: "invoice.pdf")
    photo = Ai::Attachment.new(filename: "receipt.jpg", content_type: "image/jpeg", data: file_fixture("receipts/rotated.jpg").binread)

    names = generation(files: [ photo, pdf ]).attachments.map(&:filename)

    assert_equal %w[file-1.jpg file-2-page-1.png file-2-page-2.png], names
  end

  test "an unknown category and receipt numbers outside the files are dropped" do
    answer = purchase_ai_answer(build_purchase_extraction(receipt_files: [ 1, 3 ], items: [
      { "name" => "Mug", "quantity" => 1, "unit_price" => 5, "amount" => 5, "category_name" => "food & drink", "seller" => nil },
      { "name" => "Pen", "quantity" => 1, "unit_price" => 1, "amount" => 1, "category_name" => "Office", "seller" => nil }
    ]))

    value = generation.coerce(answer.deep_stringify_keys)
    extraction = Purchase::Extraction.from_ai(value, files: 2)

    assert_equal [ "Food & Drink", nil ], extraction.items.map { _1["category_name"] }
    assert_equal [ 1 ], extraction.receipt_files
  end
end
