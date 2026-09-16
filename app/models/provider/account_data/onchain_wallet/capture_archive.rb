require "json"
require "digest"

# This logical Sync's immutable response chain, never the legacy wallet cache.
# The collector performs database reads and grant checks only, before HTTP.
class Provider::AccountData::OnchainWallet::CaptureArchive
  KEY = "onchain_capture".freeze
  VERSION = 1
  MAX_BATCHES = 8_192
  MAX_BYTES = 64 * 1024 * 1024
  MAX_STORED_BYTES = 96 * 1024 * 1024

  def self.build(connection:, sync:, observed_at:)
    unless connection.provider_key == "onchain_wallet" && sync&.persisted? && sync.syncable_type == "ProviderConnection" &&
        sync.syncable_id == connection.id && sync.created_at.to_time == observed_at.to_time
      raise Provider::AccountData::InvalidResponse, "Wallet captures require their original provider sync"
    end
    scope = { "family_id" => connection.family_id, "connection_id" => connection.id, "sync_id" => sync.id,
      "observed_at" => observed_at.to_time.getutc.iso8601(9) }
    rows = connection.ingestion_batches.where(family_id: connection.family_id, sync_id: sync.id,
      origin_kind: "provider", stream: "accounts", scope_key: "connection", external_account_id: nil)
    inventory = rows.order(:sequence, :id).limit(MAX_BATCHES + 1).pluck(:id, Arel.sql("octet_length(payload)"))
    if inventory.size > MAX_BATCHES || inventory.sum { |_id, bytes| bytes.to_i } > MAX_STORED_BYTES
      raise Provider::AccountData::IncompletePage, "Wallet capture archive exceeds its reviewed budget"
    end
    fragments, reference, bytes, completed_prefixes = {}, nil, 0, []
    inventory.each do |id, _size|
      batch = rows.where("octet_length(payload) <= ?", MAX_STORED_BYTES).find(id)
      raise ArgumentError unless %w[captured applied].include?(batch.status) && batch.mode == "snapshot"
      bytes += JSON.generate(batch.payload).bytesize
      raise Provider::AccountData::IncompletePage, "Wallet capture archive exceeds its decoded budget" if bytes > MAX_BYTES
      page = Ingestion::Codec.load(batch.payload)
      value = page.evidence.fetch(KEY)
      raise ArgumentError unless value.is_a?(Hash) && value["scope"] == scope && value["version"] == VERSION
      current = value.slice("version", "scope", "input_sha256")
      raise ArgumentError if reference && reference != current
      reference ||= current
      Provider::AccountData::RequestGrant.with_verified_capture!(connection: connection,
        capture: page.evidence.fetch(Provider::AccountData::RequestGrant::EVIDENCE_KEY), require_runtime_inputs: true, scope_sync: sync) { }
      if value["fragment"]
        raise ArgumentError unless page.records.empty? && !page.complete? && page.progress_cursor
        fragment = value.fetch("fragment")
        index = fragment.fetch("index")
        raise ArgumentError unless index.is_a?(Integer) && index >= 0 && index < MAX_BATCHES
        # Sequence restarts at zero for another attempt of the same logical
        # Sync. Only the exact same response may occupy a capture-chain slot.
        raise ArgumentError if fragments[index] && fragments[index] != fragment
        raise ArgumentError unless value["prefix_sha256"] == digest(fragment)
        fragments[index] = fragment
      else
        raise ArgumentError unless page.records.all? { |record| record.kind == "account" }
        completed_prefixes << value.fetch("prefix_sha256")
      end
    end
    ordered = fragments.sort.to_h
    raise ArgumentError unless ordered.keys == (0...ordered.size).to_a
    prefix = reference ? digest(reference) : nil
    ordered.each_value do |fragment|
      raise ArgumentError unless fragment["previous_sha256"] == prefix
      prefix = digest(fragment)
    end
    raise ArgumentError unless completed_prefixes.all? { |value| value == prefix }
    { "scope" => scope, "input_sha256" => reference&.fetch("input_sha256"), "fragments" => ordered.values }
  rescue ArgumentError, TypeError, KeyError, ActiveRecord::RecordNotFound
    raise Provider::AccountData::InvalidResponse, "Wallet captures disagree with their original sync", cause: nil
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
  end

  def self.canonical(value)
    case value
    when Hash then value.stringify_keys.sort.to_h.transform_values { |item| canonical(item) }
    when Array then value.map { |item| canonical(item) }
    when BigDecimal then value.to_s("F")
    else value
    end
  end
end
