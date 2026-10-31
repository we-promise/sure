# Recognises transactions the SimpleFIN bridge re-issued under new ids (#3436).
#
# Some bridges rotate transaction ids for transactions they already served, on a
# live account and on every reconnect. The stored payload is keyed by id, so the
# new row lands beside the old one and both become entries. Deleting either one
# does not hold, because each sync rebuilds entries from the stored payload.
#
# Stored and incoming rows are grouped by content. Within a group, stored rows
# whose id is still served keep it. The rest pair by position with the incoming
# rows whose id is not stored yet: each pair is one transaction under a new id, so
# its entry moves to the new id and the stored row gives way to the incoming one.
# Pairing by position keeps multiplicity: three identical charges map onto three,
# never one. Content-level deduplication would collapse them (#2013, #2720).
#
# Stored rows left unpaired in a group that did receive rows are dropped from the
# payload too. Their twin was served under an id that is already stored, which is
# the duplicate state this defect left behind; the entry stays, but a user who
# deletes it is no longer overruled by the next sync. A group with no incoming
# rows is never touched, so a short or partial response cannot evict history.
#
# Same pairing approach as the Enable Banking importer's rotated-id handling
# (#4159), without its window replacement.
class SimplefinAccount::TransactionIdRotation
  def initialize(stored_rows, incoming_rows)
    @stored_rows = stored_rows.to_a
    @incoming_rows = incoming_rows.to_a
  end

  # The stored rows to keep, with superseded rows removed.
  def retained_rows
    superseded, _rekeys = pairing
    stored_rows.reject { |row| superseded.include?(row) }
  end

  # Moves each rotated entry to its new id. Run it in the transaction that saves
  # the payload: an entry whose id the payload no longer mentions is duplicated
  # again by the next sync.
  def rekey_entries!(account)
    return if account.nil?

    entries = account.entries.where(source: "simplefin")
    _superseded, rekeys = pairing

    rekeys.each do |old_id, new_id|
      next if entries.exists?(external_id: "simplefin_#{new_id}")

      # One conditional UPDATE, so a concurrent sync cannot re-key the same entry twice.
      entries.where(external_id: "simplefin_#{old_id}").update_all(external_id: "simplefin_#{new_id}", updated_at: Time.current)
    end
  end

  private
    attr_reader :stored_rows, :incoming_rows

    # [stored rows superseded (an identity set), [old_id, new_id] pairs to re-key]
    def pairing
      @pairing ||= pair
    end

    def pair
      superseded = Set.new.compare_by_identity
      rekeys = []

      stored_ids = stored_rows.filter_map { |row| row_id(row) }.to_set
      incoming_ids = incoming_rows.filter_map { |row| row_id(row) }.to_set
      incoming_by_content = with_ids(incoming_rows).group_by { |row| content_key(row) }

      with_ids(stored_rows).group_by { |row| content_key(row) }.each do |key, old_rows|
        new_rows = incoming_by_content[key] or next

        unserved = old_rows.reject { |row| incoming_ids.include?(row_id(row)) }
        unstored = new_rows.reject { |row| stored_ids.include?(row_id(row)) }

        unserved.each_with_index do |old_row, index|
          superseded << old_row
          rekeys << [ row_id(old_row), row_id(unstored[index]) ] if unstored[index]
        end
      end

      [ superseded, rekeys ]
    end

    # SimplefinEntry::Processor cannot import a row without an id, so only rows
    # with one can be paired.
    def with_ids(rows)
      rows.select { |row| row_id(row) }
    end

    def row_id(row)
      row.with_indifferent_access[:id].presence&.to_s
    end

    def content_key(row)
      t = row.with_indifferent_access
      [
        epoch(t[:posted]),
        epoch(t[:transacted_at]),
        t[:amount].to_d,
        t[:description].to_s,
        t[:payee].to_s,
        SimplefinEntry::Processor.pending?(t)
      ]
    end

    # Bridges send epoch seconds or ISO strings (see Simplefin::DateUtils).
    # String#to_i would read every ISO date in a year as that year, so two
    # charges months apart would share a content group.
    def epoch(value)
      Simplefin::DateUtils.parse_provider_time(value)&.to_i
    end
end
