# A picker binds its actor, action, original credentials and exact source/cache
# inventory. Only a keyed digest enters the signed value, never credentials.
class AkahuItem::Selection
  class Invalid < Provider::AccountData::LegacyWriterFence::OwnershipChanged; end
  PURPOSE = "akahu-account-selection/v1".freeze
  FLOWS = %w[link_accounts link_existing_account complete_account_setup].freeze
  MAX_ACCOUNTS = 1000
  LINK_COLUMNS = %i[id account_id provider_id family_id provider_key external_account_id lock_version].freeze

  def self.issue(item, actor:, flow:, account_id: nil)
    raise ArgumentError, "Unknown Akahu selection flow" unless FLOWS.include?(flow.to_s)
    raise Invalid, "Akahu selection requires its actor" unless actor&.id && actor.family_id == item.family_id
    verifier.generate({ "item_id" => item.id, "family_id" => item.family_id, "actor_id" => actor.id,
      "flow" => flow.to_s, "account_id" => account_id&.to_s, "fingerprint" => fingerprint(item) },
      purpose: PURPOSE, expires_in: 15.minutes)
  end

  def self.from_token(token, actor:, flow:, account_id: nil)
    raise Invalid, "Missing Akahu selection" unless token.is_a?(String) && token.present? && token.bytesize <= 8192
    claims = verifier.verified(token, purpose: PURPOSE)
    unless claims.is_a?(Hash) && actor&.id && claims["actor_id"] == actor.id && claims["family_id"] == actor.family_id &&
        FLOWS.include?(flow.to_s) && claims["flow"] == flow.to_s && claims["account_id"] == account_id&.to_s
      raise Invalid, "Invalid or expired Akahu selection"
    end
    new(claims)
  end

  def initialize(claims)
    @claims = Provider::AccountData::MigrationManifest.copy_value(claims)
  end

  def verify_target!(flow:, account_id: nil)
    unless FLOWS.include?(flow.to_s) && @claims["flow"] == flow.to_s && @claims["account_id"] == account_id&.to_s
      raise Invalid, "Akahu selection belongs to another action or account"
    end
    true
  end

  def verify_actor!(actor_id)
    raise Invalid, "Akahu selection belongs to another actor" unless @claims["actor_id"] == actor_id
    true
  end

  def verify!(item)
    unless item.id == @claims["item_id"] && item.family_id == @claims["family_id"] &&
        ActiveSupport::SecurityUtils.secure_compare(self.class.fingerprint(item), @claims["fingerprint"].to_s)
      raise Invalid, "Akahu selection changed; open the picker again"
    end
    true
  end

  def self.fingerprint(item)
    Provider::AccountData::RuntimeInputs.fingerprint(
      { transport: AkahuItem::LegacyAccess.transport_context(item), scheduled: item.scheduled_for_deletion,
        inventory: inventory(item), control: ProviderMigrationControl.where(legacy_type: "AkahuItem", legacy_id: item.id)
          .pick(:id, :family_id, :provider_key, :provider_connection_id, :state, :writer_epoch) }, purpose: PURPOSE)
  end

  def self.inventory(item)
    # PostgreSQL tuple versions also bind encrypted cache changes without
    # decrypting potentially large statements just to validate a form.
    sources = item.akahu_accounts.order(:id).limit(MAX_ACCOUNTS + 1)
      .pluck(:id, :akahu_item_id, :account_id, Arel.sql("xmin::text"), Arel.sql("ctid::text"))
    raise Invalid, "Akahu account inventory exceeds its bound" if sources.size > MAX_ACCOUNTS
    links = AccountProvider.where(provider_type: "AkahuAccount", provider_id: sources.map(&:first)).order(:id)
      .limit(MAX_ACCOUNTS + 1).pluck(*LINK_COLUMNS)
    if links.size > MAX_ACCOUNTS || links.map { |row| row[2] }.uniq.size != links.size ||
        links.any? { |row| (row[3] && row[3] != item.family_id) || (row[4] && row[4] != "akahu") }
      raise Invalid, "Akahu account inventory has conflicting links"
    end
    { sources: sources, links: links }
  end

  def self.verifier
    Rails.application.message_verifier(PURPOSE)
  end
  private_class_method :verifier
end
