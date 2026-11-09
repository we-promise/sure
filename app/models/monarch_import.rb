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
      # Cleared first, so a destination can move between rows in one save.
      account_mappings.where(id: choices.keys).update_all(mappable_id: nil, mappable_type: nil)
      account_mappings.reload.each do |mapping|
        choice = choices[mapping.id]
        next if choice.nil?

        balance = choice[:current_balance].to_s.strip
        balance = nil if balance.empty? || balance == suggested_current_balance(mapping)
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

      targets = account_mappings.includes(:mappable).filter_map do |mapping|
        [ MonarchImport::Converter.source_id(mapping.key), mapping.target ] if mapping.target && mapping.to_converter_choice.include
      end.to_h
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

    # Opening balances moved for imported-into accounts, saved so reverting
    # can put them back.
    # Opening balances moved for imported-into accounts, saved with their
    # values before and after the import so reverting can put them back.
    def move_opening_balances!(moves)
      moved = moves.map do |move|
        before = { "date" => move.entry.date.iso8601, "amount" => move.entry.amount.to_s }
        move.entry.update!(date: move.date, amount: move.balance)
        after = { "date" => move.entry.date.iso8601, "amount" => move.entry.amount.to_s }
        { "entry_id" => move.entry.id, "account" => move.account.name, "before" => before, "after" => after }
      end
      update!(summary: summary.except("opening_balances_kept").merge("moved_opening_balances" => moved))
    end

    # Puts moved opening balances back, unless they were edited after the
    # import: then the edit is kept and listed, since restoring would undo it.
    def revert_derived_state!
      kept = Array(summary["moved_opening_balances"]).filter_map do |moved|
        entry = family.entries.find_by(id: moved["entry_id"])
        next if entry.nil?

        current = { "date" => entry.date.iso8601, "amount" => entry.amount.to_s }
        if current == moved["after"]
          entry.update!(date: moved["before"]["date"], amount: moved["before"]["amount"])
          nil
        else
          moved["account"]
        end
      end
      update!(summary: summary.except("moved_opening_balances", "records").merge("opening_balances_kept" => kept))
    end
end
