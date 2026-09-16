require "digest"

# A queued legacy job must retain its original target. This token is input
# evidence only: execution and every write still require the live item permit.
class SimplefinAccount::HoldingsRequest
  Fence = SimplefinItem::LegacyAccess::Fence
  PURPOSE = "simplefin-holdings-request-v1".freeze
  MAX_TOKEN_BYTES = 32.kilobytes

  def self.capture(source, sync: nil)
    SimplefinItem::LegacyAccess.with_account(source) do |current|
      account = current.current_account
      next unless account && %w[Investment Crypto].include?(account.accountable_type) && current.raw_holdings_payload.present?

      SimplefinItem::LegacyAccess.with_publication(current, expected_account: account) do |fresh, financial|
        claims = { "version" => 1, "family_id" => financial.family_id, "item_id" => fresh.simplefin_item_id,
          "source_id" => fresh.id, "snapshot" => snapshot(fresh, financial, sync: sync) }
        verifier.generate(claims, purpose: PURPOSE)
      end
    end
  end

  def self.from_token(token, source_id:)
    unless token.is_a?(String) && token.present? && token.bytesize <= MAX_TOKEN_BYTES
      raise Fence::OwnershipChanged, "SimpleFIN holdings job requires its original enqueue context"
    end
    claims = verifier.verified(token, purpose: PURPOSE)
    unless claims.is_a?(Hash) && claims.keys.sort == %w[family_id item_id snapshot source_id version] &&
        claims["version"] == 1 && claims["source_id"] == source_id &&
        %w[family_id item_id source_id].all? { |key| claims[key].is_a?(String) && claims[key].match?(Fence::UUID) } &&
        claims["snapshot"].is_a?(Hash) && claims["snapshot"].keys.sort == %w[financial input_digest policy selection sync writer_epoch]
      raise Fence::OwnershipChanged, "SimpleFIN holdings enqueue context is invalid"
    end
    new(claims)
  end

  def initialize(claims)
    @claims = claims.deep_dup.freeze
  end

  def with_source
    item = SimplefinItem.select(:id, :family_id).find_by(id: @claims.fetch("item_id"), family_id: @claims.fetch("family_id"))
    source = SimplefinAccount.select(:id, :simplefin_item_id).find_by(id: @claims.fetch("source_id"), simplefin_item_id: item&.id)
    unless item && source
      raise Fence::OwnershipChanged, "SimpleFIN holdings source lost its original owner"
    end
    source.simplefin_item = item
    SimplefinItem::LegacyAccess.with_account(source) do |current|
      expected = Account.instantiate(@claims.fetch("snapshot").fetch("financial"))
      admitted = SimplefinItem::LegacyAccess.with_publication(current, expected_account: expected) do |fresh, financial|
        verify!(fresh, financial)
        fresh
      end
      yield admitted
    end
  end

  # Called under LegacyAccess.with_publication, including after security lookup.
  # Financial rows are never locked while a resolver performs HTTP.
  def verify!(source, account)
    unless source.id == @claims.fetch("source_id") && source.simplefin_item_id == @claims.fetch("item_id") &&
        account.family_id == @claims.fetch("family_id")
      raise Fence::OwnershipChanged, "SimpleFIN holdings job changed its financial owner"
    end
    expected = @claims.fetch("snapshot")
    sync_id = expected.fetch("sync").first&.fetch("id")
    sync = source.simplefin_item.syncs.find_by(id: sync_id) if sync_id
    raise Fence::OwnershipChanged, "SimpleFIN holdings job lost its originating Sync" if sync_id && !sync
    unless self.class.snapshot(source, account, sync: sync) == expected
      raise Fence::OwnershipChanged, "SimpleFIN holdings enqueue context changed before publication"
    end
    true
  end

  def self.snapshot(source, account, sync:)
    if account.pending_deletion? || SimplefinItem.where(id: source.simplefin_item_id).pick(:scheduled_for_deletion)
      raise Fence::OwnershipChanged, "SimpleFIN holdings target is scheduled for deletion"
    end
    policy = Account::SourcePolicy.active.find_by(account: account, resource: "holdings")
    link = source.account_provider
    if policy && policy.account_provider_id != link&.id
      raise Fence::OwnershipChanged, "Another source owns SimpleFIN holdings publication"
    end
    {
      "financial" => account.attributes.slice(*SimplefinItem::LegacyAccess::FINANCIAL_COLUMNS, "status"),
      "selection" => { "link" => link&.attributes&.slice(*SimplefinItem::LegacyAccess::LINK_COLUMNS.map(&:to_s)),
        "direct_source_id" => account.simplefin_account_id },
      "input_digest" => Digest::SHA256.hexdigest(JSON.generate(canonical([
        source.raw_holdings_payload, source.account_id, source.name, source.account_type, source.currency, source.org_data,
        source.simplefin_item.credential_revision
      ]))),
      "policy" => policy&.attributes&.slice("id", "account_provider_id", "revision"),
      "writer_epoch" => ProviderMigrationControl.where(legacy_type: "SimplefinItem", legacy_id: source.simplefin_item_id).pick(:writer_epoch) || 0,
      "sync" => sync_lineage(source.simplefin_item, sync)
    }
  end

  def self.sync_lineage(item, sync)
    return [] unless sync
    current = Fence.scoped_sync!(item, sync, allow_completed: true)
    chain = sync_headers(item, current)
    Sync.where(id: chain.map { |row| row.fetch("id") }).order(:id).lock("FOR UPDATE NOWAIT").load
    checked = Fence.scoped_sync!(item, sync, allow_completed: true)
    unless sync_headers(item, checked) == chain
      raise Fence::OwnershipChanged, "SimpleFIN holdings Sync ancestry changed"
    end
    chain
  end

  def self.sync_headers(item, current)
    rows = []
    while current
      owner_valid = (current.syncable_type == "SimplefinItem" && current.syncable_id == item.id) ||
        (current.syncable_type == "Family" && current.syncable_id == item.family_id)
      unless owner_valid && rows.size < 64 && rows.none? { |row| row["id"] == current.id }
        raise Fence::OwnershipChanged, "SimpleFIN holdings Sync ancestry has another owner"
      end
      rows << current.attributes.slice("id", "syncable_type", "syncable_id", "parent_id")
      next_id = current.parent_id
      current = Sync.find_by(id: next_id) if next_id
      raise Fence::OwnershipChanged, "SimpleFIN holdings Sync ancestor is missing" if next_id && !current
      break unless next_id
    end
    rows
  end

  def self.canonical(value)
    case value
    when Hash then value.sort.to_h.transform_values { |child| canonical(child) }
    when Array then value.map { |child| canonical(child) }
    else value
    end
  end

  def self.verifier
    Rails.application.message_verifier(PURPOSE)
  end
  private_class_method :verifier, :canonical, :sync_lineage, :sync_headers
end
