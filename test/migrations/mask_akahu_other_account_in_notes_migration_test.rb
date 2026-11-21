# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261021060000_mask_akahu_other_account_in_notes")

class MaskAkahuOtherAccountInNotesMigrationTest < ActiveSupport::TestCase
  OTHER_ACCOUNT = "12-3456-7890123-00"

  setup do
    @account = accounts(:depository)
  end

  test "masks the other account at the end of the notes" do
    entry = akahu_entry(notes: "Coffee | Reference: 1234 | Other account: #{OTHER_ACCOUNT}")

    run_migration

    assert_equal "Coffee | Reference: 1234 | Other account: •••2300", entry.reload.notes
  end

  test "masks notes written in another language" do
    entry = akahu_entry(notes: "Gegenkonto: #{OTHER_ACCOUNT}")

    run_migration

    assert_equal "Gegenkonto: •••2300", entry.reload.notes
  end

  test "leaves other parts alone, even when they hold an account number" do
    notes = "Rent | Reference: 98-7654-3210987-00 | Code: X"
    entry = akahu_entry(notes: notes)

    run_migration

    assert_equal notes, entry.reload.notes
  end

  test "leaves notes the user edited" do
    entry = akahu_entry(notes: "Other account: #{OTHER_ACCOUNT}")
    entry.update_column(:locked_attributes, { "notes" => Time.current.iso8601 })

    run_migration

    assert_equal "Other account: #{OTHER_ACCOUNT}", entry.reload.notes
  end

  test "leaves other providers alone" do
    entry = create_entry(source: "plaid", notes: "Other account: #{OTHER_ACCOUNT}")

    run_migration

    assert_equal "Other account: #{OTHER_ACCOUNT}", entry.reload.notes
  end

  private

    def akahu_entry(notes:)
      create_entry(source: "akahu", notes: notes)
    end

    def create_entry(source:, notes:)
      @account.entries.create!(
        name: "Payment", date: Date.current, amount: 10, currency: "USD",
        source: source, external_id: SecureRandom.uuid, notes: notes,
        entryable: Transaction.new(extra: { "akahu" => { "other_account" => OTHER_ACCOUNT } })
      )
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        MaskAkahuOtherAccountInNotes.new.migrate(:up)
      end
    end
end
