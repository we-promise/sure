# Akahu used to append the counterparty's full account number to a
# transaction's notes, e.g.
#   Coffee | Reference: 1234 | Other account: 12-3456-7890123-00
# Notes are shown, exported and passed to the assistant. New imports keep only
# the last 4 digits; this masks the numbers in notes already stored.
#
# Only Akahu entries whose notes the user has not edited (notes not locked)
# are touched, and only a number in New Zealand's account format that ends a
# "<label>: <value>" part, so the label in whichever language the note was
# written in is kept.
class MaskAkahuOtherAccountInNotes < ActiveRecord::Migration[8.1]
  BATCH_SIZE = 500
  PREFIX = "•••"

  # Bank-branch-account-suffix, the suffix having 2 or 3 digits.
  ACCOUNT_NUMBER_SQL = "[0-9]{2}-[0-9]{4}-[0-9]{7}-[0-9]{2,3}"
  OTHER_ACCOUNT = /(?<=: )\d{2}-\d{4}-\d{7}-\d{2,3}(?= \| |\z)/

  def up
    last_id = nil

    loop do
      after = last_id ? "AND id > #{connection.quote(last_id)}" : ""
      rows = select_rows(<<~SQL)
        SELECT id, notes FROM entries
        WHERE source = 'akahu'
          AND notes ~ #{connection.quote(ACCOUNT_NUMBER_SQL)}
          AND NOT (COALESCE(locked_attributes, '{}'::jsonb) ? 'notes')
          #{after}
        ORDER BY id LIMIT #{BATCH_SIZE}
      SQL
      break if rows.empty?

      rows.each do |id, notes|
        masked = notes.gsub(OTHER_ACCOUNT) { |number| "#{PREFIX}#{number.delete("-").last(4)}" }
        next if masked == notes

        # Skip the row if its notes changed or got locked since the SELECT.
        execute <<~SQL
          UPDATE entries SET notes = #{connection.quote(masked)}
          WHERE id = #{connection.quote(id)}
            AND notes = #{connection.quote(notes)}
            AND NOT (COALESCE(locked_attributes, '{}'::jsonb) ? 'notes')
        SQL
      end
      last_id = rows.last.first
    end
  end

  def down
    # The full numbers are still in the Akahu account's raw transactions
    # payload; they are not written back into notes.
  end
end
