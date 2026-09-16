# Versioned composition of the existing lossless Page codec. This envelope is
# stored only in encrypted ingestion payloads, never in checkpoint metadata.
class Ingestion::TransactionGroupCodec
  KEYS = %w[version kind generation_id start_cursor request_cursor next_cursor complete account_pages unassigned_removed_ids evidence].freeze

  def self.dump(group)
    raise ArgumentError unless group.is_a?(Provider::AccountData::TransactionGroup)
    evidence = Ingestion::Codec.dump(Provider::AccountData::Page.new(records: [], complete: false, evidence: group.evidence)).fetch("evidence")
    { "version" => 1, "kind" => "transaction_group", "generation_id" => group.generation_id,
      "folding_policy" => group.folding_policy, "resource" => group.resource,
      "start_cursor" => group.start_cursor, "request_cursor" => group.request_cursor, "next_cursor" => group.next_cursor,
      "complete" => group.complete?, "account_pages" => group.account_pages.transform_values { |page| Ingestion::Codec.dump(page) },
      "unassigned_removed_ids" => group.unassigned_removed_ids, "evidence" => evidence }
  end

  def self.load(payload)
    unless payload.is_a?(Hash) && (payload.keys - %w[folding_policy resource]).sort == KEYS.sort && payload["version"].instance_of?(Integer) &&
        payload["version"] == 1 && payload["kind"] == "transaction_group" && payload["account_pages"].is_a?(Hash)
      raise ArgumentError
    end
    evidence_page = Ingestion::Codec.dump(Provider::AccountData::Page.new(records: [], complete: false)).merge("evidence" => payload.fetch("evidence"))
    Provider::AccountData::TransactionGroup.new(generation_id: payload.fetch("generation_id"), start_cursor: payload.fetch("start_cursor"),
      folding_policy: payload.fetch("folding_policy", "page_ordered"), resource: payload.fetch("resource", "transactions"),
      request_cursor: payload.fetch("request_cursor"), next_cursor: payload.fetch("next_cursor"), complete: payload.fetch("complete"),
      account_pages: payload.fetch("account_pages").transform_values { |page| Ingestion::Codec.load(page) },
      unassigned_removed_ids: payload.fetch("unassigned_removed_ids"), evidence: Ingestion::Codec.load(evidence_page).evidence)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise ArgumentError, "Invalid transaction group payload", cause: nil
  end
end
