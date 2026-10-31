# Mercury used to append its structured `details` object to a transaction's
# notes as a Ruby hash string, e.g.
#   Rent - {"electronicRoutingInfo" => {"accountNumber" => "123456789012", ...}}
# That puts the counterparty's account and routing numbers (and IBAN) into
# notes, which are shown, exported and passed to the assistant. New imports no
# longer do this; this removes the hash from notes already stored.
#
# Only Mercury entries whose notes the user has not edited (notes not locked)
# are touched, and only the trailing hash: the user-facing note in front of it
# is kept.
class RemoveMercuryRoutingDetailsFromNotes < ActiveRecord::Migration[8.1]
  # Each batch commits on its own, so a sync writing the same entries during
  # the deploy is not blocked until the whole migration ends; every update is
  # guarded by the notes it read, so a rerun or an interleaved edit is safe.
  disable_ddl_transaction!

  BATCH_SIZE = 500

  # Top-level keys of Mercury's transaction `details` object.
  DETAILS_KEYS = %w[
    address domesticWireRoutingInfo electronicRoutingInfo
    internationalWireRoutingInfo debitCardInfo creditCardInfo
  ].freeze

  # The hash always came last: either the whole note, or after " - ".
  # Matches Ruby's Hash#inspect with and without spaces around "=>", and only
  # when it starts with one of the details keys, so a note that merely ends
  # in some other hash-like text is kept.
  DETAILS_HASH = /(?:\A| - )\{"(?:#{DETAILS_KEYS.join("|")})" ?=> ?.*\}\z/m

  def up
    last_id = nil

    loop do
      after = last_id ? "AND id > #{connection.quote(last_id)}" : ""
      rows = select_rows(<<~SQL)
        SELECT id, notes FROM entries
        WHERE source = 'mercury'
          AND notes LIKE '%{"%=>%}%'
          AND NOT (COALESCE(locked_attributes, '{}'::jsonb) ? 'notes')
          #{after}
        ORDER BY id LIMIT #{BATCH_SIZE}
      SQL
      break if rows.empty?

      rows.each do |id, notes|
        cleaned = strip_details(notes)
        next if cleaned == notes

        # Skip the row if its notes changed or got locked since the SELECT.
        execute <<~SQL
          UPDATE entries SET notes = #{connection.quote(cleaned)}
          WHERE id = #{connection.quote(id)}
            AND notes = #{connection.quote(notes)}
            AND NOT (COALESCE(locked_attributes, '{}'::jsonb) ? 'notes')
        SQL
      end
      last_id = rows.last.first
    end
  end

  def down
    # The removed details are still in the Mercury account's raw transactions
    # payload; they are not written back into notes.
  end

  private

    def strip_details(notes)
      match = notes.match(DETAILS_HASH)
      return notes unless match

      notes[0...match.begin(0)].presence
    end
end
