# Imports Monarch's balance history and transactions exports.
#
# The balances export is attached; the optional transactions export is the
# import's raw_file_str. Each Monarch account gets an
# Import::MonarchAccountMapping holding the person's choice for it. Publishing
# converts both exports with MonarchImport::Converter and imports the result
# through Family::DataImporter, so the accounts and entries belong to this
# import and reverting it removes them.
class MonarchImport < Import
  has_one_attached :balances_file, dependent: :purge_later

  # Deleting a published import removes its entries, so it also has to put
  # back what publishing changed in accounts it didn't create. That includes
  # a failed import whose data committed before the failure.
  before_destroy :restore_existing_accounts!, if: :changed_existing_accounts?
  after_destroy_commit -> { family.sync_later }, unless: :pending?

  def requires_csv_workflow?
    false
  end

  def column_keys
    []
  end

  def required_column_keys
    []
  end

  def mapping_steps
    []
  end

  def csv_template
    nil
  end

  def account_mappings
    mappings.where(type: "Import::MonarchAccountMapping")
  end

  # Replaces the exports and suggests a choice for every account in them.
  # Raises MonarchImport::Exports::Error when a file isn't a Monarch export.
  def attach_exports!(balances_csv:, transactions_csv: nil)
    exports = MonarchImport::Exports.new(balances_csv: balances_csv, transactions_csv: transactions_csv)

    transaction do
      balances_file.attach(io: StringIO.new(balances_csv), filename: "balances.csv", content_type: "text/csv")
      update!(raw_file_str: transactions_csv.presence)
      account_mappings.destroy_all
      exports.suggestions.each do |suggestion|
        account_mappings.create!(
          key: suggestion.name,
          create_when_empty: true,
          choices: { "type" => suggestion.type, "closed" => suggestion.closed }
        )
      end
    end
    @exports = exports
  end

  def exports
    @exports ||= MonarchImport::Exports.new(balances_csv: balances_file.download, transactions_csv: raw_file_str)
  end

  # Mappings in the order the exports suggest: most recently active first.
  def ordered_account_mappings
    order = exports.suggestions.each_with_index.to_h { |suggestion, index| [ suggestion.name, index ] }
    account_mappings.includes(:mappable).sort_by { |mapping| order.fetch(mapping.key, order.size) }
  end

  def suggestion_for(name)
    @suggestions_by_name ||= exports.suggestions.index_by(&:name)
    @suggestions_by_name[name]
  end

  # Monarch's latest balance for the account as Sure shows it, with amounts
  # owed positive: what "Balance today" starts at.
  def suggested_current_balance(mapping)
    balance = suggestion_for(mapping.key)&.latest_balance
    return if balance.nil?

    balance = -balance if MonarchImport::Converter::LIABILITY_TYPES.include?(mapping.target&.accountable_type || mapping.type)
    ActiveSupport::NumberHelper.number_to_rounded(balance, precision: 2)
  end

  # Saves the person's choices, keyed by mapping ID. target_id picks one of
  # target_accounts to import into; a balance equal to the suggested one is
  # stored as no change.
  def apply_account_choices!(choices, target_accounts:)
    transaction do
      # The balances the form showed, before the destinations they depend on
      # are cleared.
      shown_balances = account_mappings.includes(:mappable).to_h { |mapping| [ mapping.id, suggested_current_balance(mapping) ] }
      # Cleared first, so a destination can move between rows in one save.
      account_mappings.where(id: choices.keys).update_all(mappable_id: nil, mappable_type: nil)
      account_mappings.reload.each do |mapping|
        choice = choices[mapping.id]
        next if choice.nil?

        balance = choice[:current_balance].to_s.strip
        balance = nil if balance.empty? || balance == shown_balances[mapping.id]
        name = choice[:name].to_s.strip
        mapping.update!(
          mappable: choice[:target_id].presence && target_accounts.find(choice[:target_id]),
          choices: {
            "name" => (name unless name.empty? || name == mapping.key),
            "type" => choice[:type],
            "closed" => choice[:closed] == "1",
            "include" => choice[:include] == "1",
            "transactions" => choice[:transactions] == "1",
            "current_balance" => balance
          }
        )
      end
    end
    @conversion = nil
  end

  def uploaded?
    balances_file.attached?
  end

  def configured?
    uploaded? && account_mappings.any? && account_mappings.all?(&:valid?)
  end

  def cleaned?
    configured?
  end

  def publishable?
    cleaned? && account_mappings.any? { |mapping| mapping.to_converter_choice.include }
  end

  def publishable_from_validation_stats?(invalid_rows_count:)
    super && publishable?
  end

  # Moving an existing account's opening balance or changing its status is
  # worth publishing even when no new records come with it.
  def changes_existing_records?
    configured? && (conversion.opening_balance_moves.any? || target_status_changes.any?)
  end

  # An import that only changes existing accounts commits no entries or
  # accounts, but records its changes in the same transaction.
  def data_committed?
    super || changed_existing_accounts?
  end

  # A lost job may have died after its transaction committed. Then the import
  # is done, as Import.clean decides, and failing it would let a retry import
  # everything again.
  def force_fail!(error_message = self.class.lost_error_message)
    completed = with_lock do
      next false unless importing? && presumed_lost? && data_committed?

      update!(status: :complete, error: nil)
    end
    return super unless completed

    family.sync_later
    true
  end

  # Existing accounts the publisher must be able to write to: the ones it
  # imports into, and the ones it has already changed.
  def preexisting_target_account_ids
    included = account_mappings.includes(:mappable).select { |mapping| mapping.target && mapping.to_converter_choice.include }
    changed = Array(summary["moved_opening_balances"]).map { |moved| moved["account_id"] } +
      Array(summary["status_changes"]).map { |change| change["account_id"] }
    (included.map { |mapping| mapping.target.id } + changed.compact).uniq
  end

  # Existing accounts whose status follows the Monarch account's: Closed
  # disables an active account, and Open enables a disabled one.
  def target_status_changes
    account_mappings.includes(:mappable).filter_map do |mapping|
      account = mapping.target
      choice = mapping.to_converter_choice
      next unless account && choice.include

      if choice.closed && account.may_disable?
        [ account, "disabled" ]
      elsif !choice.closed && account.disabled?
        [ account, "active" ]
      end
    end
  end

  def conversion
    @conversion ||= MonarchImport::Converter.new(
      exports: exports,
      choices: account_mappings.includes(:mappable).map(&:to_converter_choice),
      family: family
    ).result
  end

  def dry_run
    return {} unless configured?

    stats = conversion.stats
    {
      accounts: stats["Account"],
      transactions: stats["Transaction"],
      valuations: stats["Valuation"],
      categories: stats["Category"] - stats["categories_reusing_existing"],
      merchants: stats["Merchant"] - stats.fetch("merchants_reusing_existing", 0),
      tags: stats["Tag"]
    }
  end

  # What the person should know before publishing, beyond the counts.
  def review
    result = conversion
    new_names = account_mappings.reject(&:target).select { |mapping| mapping.to_converter_choice.include }.map(&:account_name)
    {
      existing_account_names: family.accounts.where(name: new_names).distinct.order(:name).pluck(:name),
      conflicting_days: result.conflicts.values.sum(&:size),
      overlapping_transactions: result.overlapping_transactions.values.sum,
      moved_opening_balances: result.opening_balance_moves.size,
      already_in_sure: result.stats.fetch("transactions_skipped_already_in_sure", 0),
      opening_balances_kept: opening_balances_kept_after_revert
    }
  end

  # Accounts whose opening balance was edited after the import, so undoing
  # it left the edit in place.
  def opening_balances_kept_after_revert
    Array(summary["opening_balances_kept"])
  end

  def import!
    result = conversion

    transaction do
      move_opening_balances!(result.opening_balance_moves)

      change_target_statuses!
      included_targets = account_mappings.includes(:mappable).select { |mapping| mapping.target && mapping.to_converter_choice.include }
      targets = included_targets.to_h { |mapping| [ MonarchImport::Converter.source_id(mapping.key), mapping.target ] }
      imported = Family::DataImporter.new(family, ndjson(result.records), import: self, account_targets: targets).import!

      Account.where(id: imported[:accounts].map(&:id)).update_all(import_id: id)
      Entry.where(id: imported[:entries].map(&:id)).update_all(import_id: id)
      update!(summary: summary.merge("records" => imported[:summary]))
    end
  end

  private
    def ndjson(records)
      records.map { |record| record.to_json }.join("\n")
    end

    def changed_existing_accounts?
      summary["moved_opening_balances"].present? || summary["status_changes"].present?
    end

    # Opening balances moved for imported-into accounts, saved with their
    # values before and after the import so reverting can put them back. The
    # moved balance is in the account's currency, so the entry takes it too.
    def move_opening_balances!(moves)
      moved = moves.map do |move|
        entry = move.entry
        before = opening_values(entry)
        # Locked, and checked against what the conversion read, so an edit
        # made since then isn't overwritten.
        entry.lock!
        raise I18n.t("activerecord.errors.models.monarch_import.opening_balance_changed", account: move.account.name) if opening_values(entry) != before

        entry.update!(date: move.date, amount: move.balance, currency: move.account.currency)
        { "entry_id" => entry.id, "account_id" => move.account.id, "account" => move.account.name,
          "before" => before, "after" => opening_values(entry) }
      end
      update!(summary: summary.except("opening_balances_kept").merge("moved_opening_balances" => moved))
    end

    def opening_values(entry)
      { "date" => entry.date.iso8601, "amount" => entry.amount.to_s, "currency" => entry.currency }
    end

    # Saved so reverting can undo each change while it is still the latest.
    def change_target_statuses!
      changes = target_status_changes.map do |account, status|
        previous_disabled_at = account.disabled_at
        status == "disabled" ? account.disable! : account.enable!
        { "account_id" => account.id, "status" => status, "disabled_at" => account.disabled_at&.iso8601(6),
          "previous_disabled_at" => previous_disabled_at&.iso8601(6) }
      end
      update!(summary: summary.merge("status_changes" => changes))
    end

    def revert_derived_state!
      kept = restore_existing_accounts!
      update!(summary: summary.except("moved_opening_balances", "status_changes", "records").merge("opening_balances_kept" => kept))
    end

    # Undoes status changes and puts moved opening balances back, unless they
    # were changed again after the import: then the later change is kept,
    # since restoring would undo it. Returns the names of accounts whose
    # opening balance edit was kept.
    def restore_existing_accounts!
      restore_target_statuses!

      Array(summary["moved_opening_balances"]).filter_map do |moved|
        # Locked, so an edit can't land between the comparison and the restore.
        entry = family.entries.lock.find_by(id: moved["entry_id"])
        next if entry.nil?

        if opening_values(entry).slice(*moved["after"].keys) == moved["after"]
          entry.update!(moved["before"])
          nil
        else
          moved["account"]
        end
      end
    end

    # An enable clears disabled_at, so a disabled account that was reopened
    # and closed again shows a different disabled_at and stays as it is.
    def restore_target_statuses!
      Array(summary["status_changes"]).each do |change|
        account = family.accounts.lock.find_by(id: change["account_id"])
        next if account.nil? || account.status != change["status"]

        if change["status"] == "disabled"
          account.enable! if account.disabled_at&.iso8601(6) == change["disabled_at"]
        else
          account.disable!
          account.update!(disabled_at: change["previous_disabled_at"]) if change["previous_disabled_at"]
        end
      end
    end
end
