# Akahu used to append the counterparty's full account number to a
# transaction's notes, e.g.
#   Coffee | Reference: 1234 | Other account: 12-3456-7890123-00
# Notes are shown, exported and passed to the assistant. New imports keep only
# the last 4 digits; this masks the numbers in notes already stored.
#
# The number is taken from the transaction's stored Akahu metadata and only
# replaced where it ends the notes, which is where the importer put it, so
# the label (in whichever language the note was written) and every other part
# stay as they are. Notes the user has edited (notes locked) are left alone.
class MaskAkahuOtherAccountInNotes < ActiveRecord::Migration[8.1]
  BATCH_SIZE = 500
  PREFIX = "•••"

  def up
    last_id = nil

    loop do
      after = last_id ? "AND entries.id > #{connection.quote(last_id)}" : ""
      rows = select_rows(<<~SQL)
        SELECT entries.id, entries.notes, transactions.extra -> 'akahu' ->> 'other_account'
        FROM entries
        JOIN transactions ON transactions.id = entries.entryable_id
          AND entries.entryable_type = 'Transaction'
        WHERE entries.source = 'akahu'
          AND transactions.extra -> 'akahu' ->> 'other_account' <> ''
          AND entries.notes IS NOT NULL
          AND NOT (COALESCE(entries.locked_attributes, '{}'::jsonb) ? 'notes')
          #{after}
        ORDER BY entries.id LIMIT #{BATCH_SIZE}
      SQL
      break if rows.empty?

      rows.each do |id, notes, other_account|
        masked = mask(notes, other_account)
        next unless masked

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
    # The full numbers are still in the transactions' Akahu metadata; they are
    # not written back into notes.
  end

  private

    # Same output as the importer: dashes dropped, last 4 characters kept.
    def mask(notes, other_account)
      suffix = ": #{other_account}"
      digits = other_account.delete("-")
      return nil unless notes.end_with?(suffix) && digits.length > 4

      "#{notes.delete_suffix(other_account)}#{PREFIX}#{digits.last(4)}"
    end
end
