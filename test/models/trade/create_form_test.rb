require "test_helper"

class Trade::CreateFormTest < ActiveSupport::TestCase
  include GoalPledgeTestHelper

  setup do
    @account = accounts(:investment)
  end

  # The API runs the form inside its own transaction, so a pledge must wait
  # for that to commit rather than resolve inside it.
  test "an unlinked deposit resolves its pledge only once the caller's transaction commits" do
    pledge = open_transfer_pledge(@account, amount: 250)

    ApplicationRecord.transaction do
      Trade::CreateForm.new(account: @account, type: "deposit", date: Date.current, amount: 250, currency: "USD").create

      assert_equal "open", pledge.reload.status
    end

    assert_equal "matched", pledge.reload.status
  end
end
