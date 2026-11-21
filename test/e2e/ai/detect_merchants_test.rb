require "test_helper"

class AiE2eDetectMerchantsTest < ActiveSupport::TestCase
  include AiE2eHelper, EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", balance: 1000, currency: "USD", accountable: Depository.new)
    @transactions = [ "STARBUCKS 1234 SEATTLE", "NETFLIX.COM 866-579-7172", "AMZN MKTP US*2K4" ]
                      .map { create_transaction(account: @account, name: _1).transaction }
  end

  test "Kilo detects merchants through the job" do
    with_live_ai do
      Ai::GenerationJob.perform_now(:detect_merchants, { ids: @transactions.map(&:id), family_id: @family.id })
    end

    merchants = @transactions.map { _1.reload.merchant }
    assert merchants.compact.any?, "no merchant was detected"
    assert merchants.compact.all? { _1.name.present? }
    assert_ai_usage(@family, :detect_merchants)
    assert_no_ai_errors
  end
end
