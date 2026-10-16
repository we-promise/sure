# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261016060000_remove_mercury_routing_details_from_notes")

class RemoveMercuryRoutingDetailsFromNotesMigrationTest < ActiveSupport::TestCase
  DETAILS = '{"electronicRoutingInfo" => {"accountNumber" => "123456789012", "routingNumber" => "021000021"}}'
  DETAILS_COMPACT = '{"electronicRoutingInfo"=>{"accountNumber"=>"123456789012", "routingNumber"=>"021000021"}}'

  setup do
    @account = accounts(:depository)
  end

  test "keeps the note and drops the details hash after it" do
    entry = mercury_entry(notes: "Rent - #{DETAILS}")

    run_migration

    assert_equal "Rent", entry.reload.notes
  end

  test "clears notes that held only the details hash" do
    entry = mercury_entry(notes: DETAILS_COMPACT)

    run_migration

    assert_nil entry.reload.notes
  end

  test "leaves notes the user edited" do
    entry = mercury_entry(notes: "Rent - #{DETAILS}")
    entry.update_column(:locked_attributes, { "notes" => Time.current.iso8601 })

    run_migration

    assert_equal "Rent - #{DETAILS}", entry.reload.notes
  end

  test "leaves other providers and plain Mercury notes alone" do
    other = create_entry(source: "plaid", notes: "Rent - #{DETAILS}")
    plain = mercury_entry(notes: "Office supplies - Q1 restock")

    run_migration

    assert_equal "Rent - #{DETAILS}", other.reload.notes
    assert_equal "Office supplies - Q1 restock", plain.reload.notes
  end

  private

    def mercury_entry(notes:)
      create_entry(source: "mercury", notes: notes)
    end

    def create_entry(source:, notes:)
      @account.entries.create!(
        name: "Payment", date: Date.current, amount: 10, currency: "USD",
        source: source, external_id: SecureRandom.uuid, notes: notes,
        entryable: Transaction.new
      )
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        RemoveMercuryRoutingDetailsFromNotes.new.migrate(:up)
      end
    end
end
