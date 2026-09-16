require "set"

# Some provider events create two financial legs. A retry or migration must not
# invent a missing leg after the legacy importer already accepted the event.
class Ingestion::ActivityGroups
  def initialize(page:, account:, source:)
    @page, @account, @source = page, account, source
  end

  def insertion_exclusions
    exclusions = Set.new
    groups = @page.records.select { |record| record[:metadata]&.dig(:atomic_group) || record[:metadata]&.dig("atomic_group") }
      .group_by { |record| group_for(record).fetch(:id) }
    groups.each do |id, records|
      group = group_for(records.first)
      members = group[:members]
      unless id.is_a?(String) && id.present? && group[:policy] == "insert_pair_if_absent" &&
          members.is_a?(Array) && members.size == 2 && members.all? { |member| member.is_a?(Hash) } &&
          members.map { |member| member[:financial_type] }.tally == { "Trade" => 1, "Transaction" => 1 }
        raise Provider::AccountData::InvalidResponse, "Invalid atomic activity group"
      end
      ids = members.map { |member| member[:external_id] }
      unless ids.all? { |value| value.is_a?(String) && value.present? } && ids.uniq.size == 2 &&
          records.map { |record| record[:external_id] }.sort == ids.sort
        raise Provider::AccountData::InvalidResponse, "Atomic activity group must be captured in one complete pair"
      end
      types = members.to_h { |member| [ member[:external_id], member[:financial_type] ] }
      records.each do |record|
        metadata = record[:metadata].with_indifferent_access
        type = record.ledger_type == "trade" ? "Trade" : "Transaction"
        unless record.kind == "activity" && group_for(record) == group && metadata[:update_policy] == "insert_only" && types.fetch(record[:external_id]) == type
          raise Provider::AccountData::InvalidResponse, "Atomic activity group has inconsistent financial legs"
        end
      end
      existing = @account.entries.where(source: @source, external_id: ids).index_by(&:external_id)
      existing.each do |external_id, entry|
        unless entry.entryable_type == types.fetch(external_id)
          raise Provider::AccountData::InvalidResponse, "Atomic activity identity has a different financial type"
        end
      end
      exclusions.merge(ids - existing.keys) if existing.any?
    end
    exclusions
  rescue KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid atomic activity group", cause: nil
  end

  private
    def group_for(record)
      record[:metadata].with_indifferent_access.fetch(:atomic_group).with_indifferent_access
    end
end
