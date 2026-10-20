class Rule::ActionExecutor::AppendTransactionNotes < Rule::ActionExecutor
  def label
    I18n.t("rules.action_executors.append_transaction_notes")
  end

  def type
    "text"
  end

  def options
    nil
  end

  # Appended lines add up like tags: several appending rules may each add
  # their line. A rule above that replaces the notes still wins, and an
  # append keeps replacing rules further down away (see SetTransactionNotes).
  def claimed_attributes
    [ :appended_notes ]
  end

  def blocking_attributes
    [ :notes ]
  end

  # A blank value changes nothing, so it must not keep note rules below away.
  def actionable?(value)
    value.to_s.strip.present?
  end

  # Adds the text as a new line. Rules run again on every sync, so a line is
  # only added when no line of the notes already equals it; otherwise the notes
  # would grow every night. A value with several lines (API, imports) is
  # checked line by line, so it converges the same way.
  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    lines = value.to_s.lines.map(&:strip).reject(&:blank?).uniq
    return 0 if lines.empty?

    scope = transaction_scope.with_entry
    unless ignore_attribute_locks
      # Notes live on Entry, so check entries.locked_attributes
      scope = scope.where.not(
        Arel.sql("entries.locked_attributes ? 'notes'")
      )
    end

    count_modified_resources(scope) do |txn|
      # The new notes are built from the current ones, so read, compare and
      # save under a row lock: an edit committed in between (which may also
      # lock the notes) is then seen instead of being overwritten. Not
      # entry.with_lock: Entry#transaction is the delegated-type reader.
      Entry.transaction do
        txn.entry.lock!
        notes = txn.entry.notes.to_s
        missing = lines - notes.lines.map(&:strip)

        if missing.empty?
          false
        else
          text = missing.join("\n")
          txn.entry.enrich_attribute(
            :notes,
            notes.blank? ? text : "#{notes.rstrip}\n#{text}",
            source: "rule",
            ignore_locks: ignore_attribute_locks
          )
        end
      end
    rescue ActiveRecord::RecordNotFound
      # Deleted since the scope was loaded: nothing left to append to.
      false
    end
  end
end
