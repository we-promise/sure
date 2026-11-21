require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::CaptureLockOrderTest < ActiveSupport::TestCase
  include FinancekitTestHelper
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "FinanceKit capture lock order", currency: "USD")
    @user = User.create!(family: @family, email: "capture-lock-#{SecureRandom.hex(4)}@example.com",
      password: "password123", role: :admin)
    @source_id = SecureRandom.uuid
    @balance_id = SecureRandom.uuid
    @transaction_id = SecureRandom.uuid
    @enrollment = {
      "enrollment_id" => SecureRandom.uuid,
      "protocol_version" => Financekit::VERSION,
      "consent" => {
        "version" => 1,
        "granted_at" => Time.current.iso8601,
        "selected_source_account_ids" => [ @source_id ],
        "upload_authorized" => true,
        "family_visibility_acknowledged" => true,
        "remote_processing_acknowledged" => true
      }
    }
    @item = Financekit::Enrollment.create!(@user, @enrollment).item
    @mapping_input = {
      "expected_version" => 0,
      "action" => "create",
      "name" => "Test Wallet",
      "institution_name" => "Apple Wallet",
      "currency" => "USD",
      "accountable_type" => "Depository",
      "subtype" => "checking",
      "ledger_timezone" => "America/Los_Angeles",
      "booked_balance" => money("125.00", "credit"),
      "observed_at" => Time.current.iso8601
    }
    @source = FinancekitAccount.map!(@item, @source_id, @mapping_input)
    @credential = @item.activate!
  end

  teardown do
    # Debug log rows outlive the family association by design; remove them
    # explicitly because this test does not run in a rolled-back transaction.
    DebugLogEntry.where(family_id: @family.id).delete_all
    @family&.destroy!
  end

  test "locks every existing capture transaction before the first event" do
    purchase_source_id = SecureRandom.uuid
    refund_source_id = SecureRandom.uuid

    first = accept_and_apply(financekit_payload(events: [
      *financekit_events.first(2),
      transaction_event(@transaction_id, "PURCHASE"),
      transaction_event(purchase_source_id, "REFUND")
    ]))

    identities = FinancekitTransaction
      .where(financekit_account_id: @source.id, source_id: [ @transaction_id, purchase_source_id ])
      .includes(:entry)
      .to_a
    transactions = identities.map { |identity| identity.entry.transaction }
    greater, lesser = transactions.sort_by(&:id).reverse

    # The first event targets the higher id, which is the order a capture used
    # before it pre-locked; the refund path locks the lower id first.
    events = transactions.sort_by(&:id).reverse.map do |transaction|
      identity = identities.find { |record| record.entry.entryable_id == transaction.id }
      transaction_event(identity.source_id, transaction.entry.name)
    end
    accept_batch(financekit_payload(sequence: 2, predecessor_digest: first.payload_digest, events: events))

    locked = nil
    processor_class = Class.new(Financekit::Processor) do
      attr_accessor :on_first_event

      private
        def apply_event!(event, mappings, batch, counts)
          unless @probed_first_event
            @probed_first_event = true
            @on_first_event.call
          end
          super
        end
    end
    processor = processor_class.new(@item)
    processor.on_first_event = -> { locked = rows_locked_by_another_connection?([ greater.id, lesser.id ]) }

    assert processor.apply_next!.present?
    assert locked, "both existing transaction rows must be locked before the first event is applied"
  end

  private
    def transaction_event(source_id, description)
      event = financekit_events.last.deep_dup
      event["transaction"]["source_id"] = source_id
      event["transaction"]["transaction_description"] = description
      event["transaction"]["original_transaction_description"] = description.upcase
      event
    end

    # A second connection is the only way to observe row locks held by the
    # processing connection.
    def rows_locked_by_another_connection?(ids)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          ids.all? do |id|
            begin
              connection.select_values(
                "SELECT id FROM transactions WHERE id = #{connection.quote(id)} FOR UPDATE NOWAIT"
              )
              false
            rescue ActiveRecord::StatementInvalid
              true
            end
          end
        end
      end.value
    end
end
