# The fields whose changes invalidate a pre-native identity sweep. Presentation,
# amounts, categories and user protections deliberately remain outside this state.
class Ingestion::FinancialIdentityState
  ENTRY_KEYS = %w[entryable_id source external_id plaid_id].freeze

  def self.from_snapshot(snapshot)
    entry = snapshot.fetch("entry")
    state = entry.slice(*ENTRY_KEYS)
    state["pending_metadata"] = if entry.fetch("entryable_type") == "Transaction"
      extra = snapshot.fetch("entryable")["extra"]
      extra = {} if extra.nil?
      if extra.is_a?(Hash)
        providers = Transaction::PENDING_PROVIDERS.dup
        providers << entry["source"] if Provider::AccountData::FinancialIdentityManifest::PROVIDER_KEYS.include?(entry["source"])
        { "aliases" => extra["auto_claimed_pending_ids"], "providers" => providers.uniq.to_h do |provider|
          data = extra[provider]
          value = if data.is_a?(Hash)
            { "pending" => data["pending"] }.tap { |fields| fields["pending_transaction_id"] = data["pending_transaction_id"] if provider == "plaid" }
          else
            data
          end
          [ provider, value ]
        end }
      else
        extra
      end
    end
    state
  end

  # Trusted table aliases used by IdentityBootstrap's terminal relation. Compare
  # JSONB values directly instead of relying on a count or a lossy digest.
  def self.sql
    quote = ApplicationRecord.connection.method(:quote)
    extra = "COALESCE(NULLIF(bootstrap_transactions.extra, 'null'::jsonb), '{}'::jsonb)"
    providers = Transaction::PENDING_PROVIDERS.map do |provider|
      data = "(#{extra} -> #{quote.call(provider)})"
      fields = "'pending', #{data} -> 'pending'"
      fields += ", 'pending_transaction_id', #{data} -> 'pending_transaction_id'" if provider == "plaid"
      "#{quote.call(provider)}, CASE WHEN jsonb_typeof(#{data}) = 'object' THEN jsonb_build_object(#{fields}) ELSE #{data} END"
    end.join(", ")
    keys = Provider::AccountData::FinancialIdentityManifest::PROVIDER_KEYS.map { |provider| quote.call(provider) }.join(", ")
    own = "(#{extra} -> entries.source)"
    own_fields = "jsonb_build_object('pending', #{own} -> 'pending') || CASE WHEN entries.source = 'plaid' THEN jsonb_build_object('pending_transaction_id', #{own} -> 'pending_transaction_id') ELSE '{}'::jsonb END"
    own_provider = "CASE WHEN entries.source IN (#{keys}) THEN jsonb_build_object(entries.source, CASE WHEN jsonb_typeof(#{own}) = 'object' THEN #{own_fields} ELSE #{own} END) ELSE '{}'::jsonb END"
    <<~SQL.squish
      jsonb_build_object('entryable_id', entries.entryable_id, 'source', entries.source,
        'external_id', entries.external_id, 'plaid_id', entries.plaid_id,
        'pending_metadata', CASE WHEN entries.entryable_type = 'Transaction' THEN
          CASE WHEN jsonb_typeof(#{extra}) = 'object' THEN
            jsonb_build_object('aliases', #{extra} -> 'auto_claimed_pending_ids', 'providers', jsonb_build_object(#{providers}) || #{own_provider})
          ELSE #{extra} END
        ELSE NULL END)
    SQL
  end
end
