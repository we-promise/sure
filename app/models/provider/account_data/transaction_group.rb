# Provisional item-wide pages must be captured before any child page is applied.
# The shared coordinator owns generation restart, account fanout, unresolved
# removal lookup, source-policy versions and the final item checkpoint barrier.
class Provider::AccountData::TransactionGroup
  attr_reader :generation_id, :start_cursor, :request_cursor, :next_cursor, :account_pages,
    :unassigned_removed_ids, :evidence, :folding_policy, :resource

  def initialize(generation_id:, start_cursor:, request_cursor:, next_cursor:, complete:, account_pages:, unassigned_removed_ids:, evidence:, folding_policy: "page_ordered", resource: "transactions")
    policies = { "transactions" => %w[page_ordered modified_added_removed], "activities" => [ "first_observation" ] }
    raise ArgumentError unless policies.fetch(resource, []).include?(folding_policy)
    record_kind = resource == "activities" ? "activity" : "transaction"
    raise ArgumentError unless generation_id.is_a?(String) && generation_id.present? && generation_id.bytesize <= 100
    raise ArgumentError unless [ start_cursor, request_cursor, next_cursor ].all? { |value| value.nil? || (value.is_a?(String) && value.present? && value.bytesize <= 16_384) }
    raise ArgumentError unless next_cursor && [ true, false ].include?(complete)
    raise ArgumentError if !complete && next_cursor == request_cursor
    valid_pages = account_pages.is_a?(Hash) && account_pages.all? do |id, page|
      id.is_a?(String) && id.present? && page.is_a?(Provider::AccountData::Page) && !page.complete? && page.mode == "delta" &&
        page.next_cursor.nil? && page.checkpoint_cursor.nil? && page.progress_cursor.nil? && page.records.all? { |record| record.kind == record_kind } &&
        (resource == "transactions" || (page.removed_ids.empty? && page.coverage.with_indifferent_access[:removal_policy].nil? &&
          page.coverage.with_indifferent_access[:pending_absence_authoritative] != true))
    end
    raise ArgumentError unless valid_pages
    raise ArgumentError unless unassigned_removed_ids.is_a?(Array) && unassigned_removed_ids.all? { |id| id.is_a?(String) && id.present? }
    raise ArgumentError if resource == "activities" && unassigned_removed_ids.any?
    @generation_id = generation_id.dup.freeze
    @resource = resource.dup.freeze
    @folding_policy = folding_policy.dup.freeze
    @start_cursor, @request_cursor, @next_cursor = [ start_cursor, request_cursor, next_cursor ].map { |value| value&.dup&.freeze }
    @complete = complete
    @account_pages = account_pages.to_h { |key, value| [ key.dup.freeze, value ] }.freeze
    @unassigned_removed_ids = unassigned_removed_ids.map { |id| id.dup.freeze }.freeze
    @evidence = Provider::AccountData::Page.new(records: [], complete: complete, evidence: evidence).evidence
    freeze
  end

  def complete?
    @complete
  end

  def inspect
    "#<#{self.class.name} accounts=#{account_pages.size} complete=#{complete?}>"
  end
end
