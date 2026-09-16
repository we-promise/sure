# A submitted picker retains its original connection, credentials and target.
# The signed value contains a keyed fingerprint, never the API token.
class BrexItem::Selection
  class Invalid < Provider::AccountData::LegacyWriterFence::OwnershipChanged; end
  PURPOSE = "brex-account-selection/v1".freeze
  FLOWS = %w[link_accounts link_existing_account complete_account_setup].freeze

  def self.issue(item, flow:, account_id: nil)
    raise ArgumentError, "Unknown Brex selection flow" unless FLOWS.include?(flow.to_s)
    verifier.generate({ "item_id" => item.id, "family_id" => item.family_id,
      "flow" => flow.to_s, "account_id" => account_id&.to_s, "fingerprint" => fingerprint(item) },
      purpose: PURPOSE, expires_in: 15.minutes)
  end

  def self.from_token(token, flow:, account_id: nil)
    raise Invalid, "Missing Brex selection" unless token.is_a?(String) && token.present? && token.bytesize <= 8192
    claims = verifier.verified(token, purpose: PURPOSE)
    unless claims.is_a?(Hash) && FLOWS.include?(flow.to_s) && claims["flow"] == flow.to_s && claims["account_id"] == account_id&.to_s
      raise Invalid, "Invalid or expired Brex selection"
    end
    new(claims)
  end

  def initialize(claims)
    @claims = Provider::AccountData::MigrationManifest.copy_value(claims)
  end

  def verify_target!(flow:, account_id: nil)
    unless FLOWS.include?(flow.to_s) && @claims["flow"] == flow.to_s && @claims["account_id"] == account_id&.to_s
      raise Invalid, "Brex selection belongs to another action or account"
    end
    true
  end

  def verify!(item)
    unless item.id == @claims["item_id"] && item.family_id == @claims["family_id"] &&
        ActiveSupport::SecurityUtils.secure_compare(self.class.fingerprint(item), @claims["fingerprint"].to_s)
      raise Invalid, "Brex selection changed; open the picker again"
    end
    true
  end

  def self.fingerprint(item)
    Provider::AccountData::RuntimeInputs.fingerprint([ item.id, item.family_id, item.token,
      item.effective_base_url, item.sync_start_date, item.scheduled_for_deletion ], purpose: PURPOSE)
  end

  def self.cache_key(item)
    "brex_accounts_v2_#{item.family_id}_#{item.id}_#{fingerprint(item)}"
  end

  def self.verifier
    Rails.application.message_verifier(PURPOSE)
  end
  private_class_method :verifier
end
