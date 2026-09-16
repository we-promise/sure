require "set"

# Pure compilation of a fully captured generation. The coordinator must seal the
# complete page chain before applying these pages, and retain the original groups
# as evidence. Transactions retain their declared revision/removal ordering;
# activities keep the first observation of each source-account identity.
class Ingestion::TransactionGroupAssembler
  class UnresolvedRemoval < Provider::AccountData::InvalidResponse; end
  MAX_PAGES = 500
  MAX_CHANGES = 100_000

  def initialize(removal_accounts: {})
    unless removal_accounts.is_a?(Hash) && removal_accounts.all? { |id, accounts|
        id.is_a?(String) && id.present? && accounts.is_a?(Array) && accounts.all? { |value| value.is_a?(String) && value.present? }
      }
      raise ArgumentError, "Removal identities require a scoped account mapping"
    end
    @removal_accounts = removal_accounts.to_h { |id, accounts| [ id.dup.freeze, accounts.map { |value| value.dup.freeze }.uniq.freeze ] }.freeze
  end

  def assemble(groups)
    accounts = {}
    generation_id = start_cursor = expected_cursor = folding_policy = resource = nil
    seen_cursors = Set.new
    complete = false
    pages = changes = 0
    groups.each do |group|
      unless group.is_a?(Provider::AccountData::TransactionGroup) && !complete && pages < MAX_PAGES
        raise Provider::AccountData::InvalidResponse, "Invalid transaction generation"
      end
      if pages.zero?
        generation_id, start_cursor, expected_cursor = group.generation_id, group.start_cursor, group.start_cursor
        folding_policy = group.folding_policy
        resource = group.resource
      end
      unless group.generation_id == generation_id && group.start_cursor == start_cursor && group.request_cursor == expected_cursor &&
          group.folding_policy == folding_policy && group.resource == resource &&
          seen_cursors.add?(group.request_cursor) && (group.complete? || !seen_cursors.include?(group.next_cursor))
        raise Provider::AccountData::InvalidResponse, "Transaction generation changed scope or pagination order"
      end
      group.account_pages.each do |account_id, page|
        state = accounts[account_id] ||= account_state
        state[:group_pages] << pages
        changes += page.records.size + page.removed_ids.size
        raise Provider::AccountData::IncompletePage, "Transaction generation exceeds its change limit" if changes > MAX_CHANGES
        page.records.each do |record|
          next if folding_policy == "first_observation" && state[:records].key?(record[:external_id])
          if folding_policy == "modified_added_removed"
            type = record[:metadata]&.with_indifferent_access&.fetch(:change_type, nil)
            unless %w[modified added].include?(type)
              raise Provider::AccountData::InvalidResponse, "Legacy change folding requires an explicit change type"
            end
            bucket = type == "added" ? state[:added] : state[:records]
          else
            state[:removals].delete(record[:external_id])
            bucket = state[:records]
          end
          bucket.delete(record[:external_id])
          bucket[record[:external_id]] = record
        end
        page.removed_ids.each do |id|
          state[:records].delete(id) if folding_policy == "page_ordered"
          state[:removals] << id
        end
      end
      group.unassigned_removed_ids.each do |id|
        changes += 1
        raise Provider::AccountData::IncompletePage, "Transaction generation exceeds its change limit" if changes > MAX_CHANGES
        candidates = Array(@removal_accounts[id]).uniq
        unless candidates.one? && candidates.first.is_a?(String) && candidates.first.present?
          raise UnresolvedRemoval, "Transaction removal requires an unambiguous source account"
        end
        state = accounts[candidates.first] ||= account_state
        state[:group_pages] << pages
        state[:records].delete(id) if folding_policy == "page_ordered"
        state[:removals] << id
      end
      expected_cursor = group.next_cursor
      complete = group.complete?
      pages += 1
    end
    unless complete
      raise Provider::AccountData::IncompletePage, "Transaction generation has no captured terminal page"
    end
    accounts.sort.to_h.transform_values do |state|
      records = state[:records].merge(state[:added]).reject { |id, _record| state[:removals].include?(id) }.values
      coverage = { "pending_absence_authoritative" => false }
      coverage["removal_policy"] = "exact_external_id" if resource == "transactions"
      Provider::AccountData::Page.new(records: records, removed_ids: state[:removals].to_a,
        complete: true, mode: "delta", coverage: coverage,
        evidence: { "generation_id" => generation_id, "resource" => resource, "folding_policy" => folding_policy, "group_pages" => state[:group_pages].to_a })
    end
  end

  private
    def account_state
      { records: {}, added: {}, removals: Set.new, group_pages: Set.new }
    end
end
