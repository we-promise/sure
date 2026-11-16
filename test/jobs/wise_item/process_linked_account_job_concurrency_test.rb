# frozen_string_literal: true

require "test_helper"
require "concurrent"

# The job used to book the payload and link inside one transaction under the
# balance's row lock. Its first Account save locked the owner's users row
# (Account#owner_belongs_to_family) until that transaction ended, so the next
# link click, an Account save for the same owner, waited for the whole job.
# Real threads and commits, so no test transaction.
class WiseItem::ProcessLinkedAccountJobConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(family: @family, name: "Wise", token: "test_token", profile_id: "job-#{SecureRandom.hex(4)}",
                                  profile_type: :personal)
    payout = { "id" => 4711, "targetAccount" => 1234, "sourceCurrency" => "GBP", "targetCurrency" => "GBP", "sourceValue" => 25.0,
               "targetValue" => 25.0, "status" => "outgoing_payment_sent", "created" => "2026-10-10 12:00:00" }
    @gbp = WiseAccount.create!(wise_item: @wise_item, balance_id: "job-#{SecureRandom.hex(3)}", name: "Wise GBP", currency: "GBP",
                               current_balance: 0, raw_payload: { "type" => "STANDARD" }, raw_transactions_payload: [ payout ])
    @account = Account.create!(family: @family, name: "Wise GBP", accountable: Depository.new(subtype: "checking"), balance: 0, currency: "GBP")
    AccountProvider.create!(account: @account, provider: @gbp)
  end

  # Nothing here is rolled back, and account providers and debug log entries
  # have no fixtures, so rows pointing at deleted accounts would trip the
  # next fixture load.
  teardown do
    DebugLogEntry.where(family_id: @family.id).delete_all
    AccountProvider.where(provider_type: "WiseAccount", provider_id: @gbp.id).delete_all
    Account.where(id: @account.id).or(Account.where(family: @family, name: "Wise USD")).find_each(&:destroy!)
    @wise_item.reload.destroy!
  end

  test "the next account saved for the same owner does not wait for the job" do
    booked = Concurrent::Event.new
    resume = Concurrent::Event.new
    # Holds the job after it booked the balance, before it links.
    WiseItem.any_instance.stubs(:link_jar_transfers!).with { booked.set && resume.wait(30) }
    job = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { WiseItem::ProcessLinkedAccountJob.perform_now(WiseAccount.find(@gbp.id)) }
    end
    assert booked.wait(30), "the job booked the balance"

    next_account = Account.transaction do
      # A save that must wait for the job's locks fails instead of hanging.
      Account.connection.execute("SET LOCAL lock_timeout = '2s'")
      Account.create!(family: @family, name: "Wise USD", accountable: Depository.new(subtype: "checking"), balance: 0, currency: "USD")
    end
    resume.set
    job.join(30)

    assert next_account.persisted?
    assert_equal [ "wise_transfer_4711" ], @account.entries.where(source: "wise").pluck(:external_id)
  ensure
    resume&.set
    job&.join(30)
  end
end
