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
  BATCH_SIZE = 500

  # The hash always came last: either the whole note, or after " - ".
  # Matches Ruby's Hash#inspect with and without spaces around "=>".
  DETAILS_HASH = /(?:\A| - )\{"[A-Za-z_]+" ?=> ?.*\}\z/m

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

        execute "UPDATE entries SET notes = #{connection.quote(cleaned)} WHERE id = #{connection.quote(id)}"
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
