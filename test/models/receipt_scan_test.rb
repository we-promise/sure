require "test_helper"

class ReceiptScanTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "reads receipts with the preferred provider when it can" do
    anthropic = stub(supports_receipt_extraction?: true)
    Provider::Registry.stubs(:preferred_llm_provider).returns(anthropic)
    Ai.stubs(:available?).returns(true)

    assert_same anthropic, ReceiptScan.extraction_provider
    assert ReceiptScan.extraction_available?(family: @family, user: @user)
  end

  test "doesn't send receipts to another provider when the preferred one can't read them" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(stub(supports_receipt_extraction?: false))
    Provider::Registry.stubs(:get_provider).returns(stub(supports_receipt_extraction?: true))
    Ai.stubs(:available?).returns(true)

    assert_nil ReceiptScan.extraction_provider
    assert_not ReceiptScan.extraction_available?(family: @family, user: @user)
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
end
