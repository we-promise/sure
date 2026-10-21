# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261021060000_mask_akahu_other_account_in_notes")

class MaskAkahuOtherAccountInNotesMigrationTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
  end

  test "masks the other account at the end of the notes" do
    entry = akahu_entry(notes: "Coffee | Reference: 1234 | Other account: 12-3456-7890123-00")

    run_migration

    assert_equal "Coffee | Reference: 1234 | Other account: •••2300", entry.reload.notes
  end

  test "masks the other account in the middle of the notes and with a 3-digit suffix" do
    entry = akahu_entry(notes: "Gegenkonto: 12-3456-7890123-001 | Code: ABC")

    run_migration

    assert_equal "Gegenkonto: •••3001 | Code: ABC", entry.reload.notes
  end

  test "leaves notes the user edited" do
    entry = akahu_entry(notes: "Other account: 12-3456-7890123-00")
    entry.update_column(:locked_attributes, { "notes" => Time.current.iso8601 })

    run_migration

    assert_equal "Other account: 12-3456-7890123-00", entry.reload.notes
  end

  test "leaves other providers and numbers outside a labelled part alone" do
    other = create_entry(source: "plaid", notes: "Other account: 12-3456-7890123-00")
    inline = akahu_entry(notes: "Paid 12-3456-7890123-00 back")

    run_migration

    assert_equal "Other account: 12-3456-7890123-00", other.reload.notes
    assert_equal "Paid 12-3456-7890123-00 back", inline.reload.notes
  end

  private

    def akahu_entry(notes:)
      create_entry(source: "akahu", notes: notes)
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
        MaskAkahuOtherAccountInNotes.new.migrate(:up)
      end
    end
end
