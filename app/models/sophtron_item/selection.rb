# A picker identifies the connection it displayed, not whichever connection is
# configured when a later POST arrives. This is separate from authorization:
# controllers still require admin, family membership and ordinary CSRF checks.
class SophtronItem::Selection
  class Invalid < Provider::AccountData::LegacyWriterFence::OwnershipChanged; end

  PURPOSE = "sophtron-account-selection-v1".freeze
  FLOWS = %w[link_accounts link_existing_account complete_account_setup].freeze
  LIFETIME = 15.minutes

  def self.issue(item, flow:, account_id: nil)
    raise ArgumentError, "Unknown Sophtron selection flow" unless FLOWS.include?(flow.to_s)

    SophtronItem::LegacyAccess.with_item(item, operation: :ingest) do |current|
      verifier.generate({ "item_id" => current.id, "family_id" => current.family_id,
        "flow" => flow.to_s, "account_id" => account_id&.to_s,
        "fingerprint" => fingerprint(current) }, purpose: PURPOSE, expires_in: LIFETIME)
    end
  end

  def self.from_token(token, flow:, account_id: nil)
    raise Invalid, "Missing Sophtron selection" unless token.is_a?(String) && token.present? && token.bytesize <= 8192
    claims = verifier.verified(token, purpose: PURPOSE)
    unless claims.is_a?(Hash) && FLOWS.include?(flow.to_s) && claims["flow"] == flow.to_s && claims["account_id"] == account_id&.to_s
      raise Invalid, "Invalid or expired Sophtron selection"
    end
    new(claims)
  end

  def initialize(claims)
    @claims = claims
  end

  def item_for(family)
    raise Invalid, "Sophtron selection belongs to another family" unless @claims["family_id"] == family.id
    item = SophtronItem.uncached { family.sophtron_items.find_by(id: @claims["item_id"]) }
    raise Invalid, "Sophtron selection was removed" unless item
    item
  end

  # Called only after the exact selected item has entered the operation permit.
  def verify!(item)
    SophtronItem::LegacyAccess.with_item(item, operation: :lifecycle) do |current|
      fresh = SophtronItem.uncached { SophtronItem.find_by(id: current.id, family_id: current.family_id) }
      unless fresh && fresh.id == @claims["item_id"] && fresh.family_id == @claims["family_id"] &&
          !fresh.scheduled_for_deletion? &&
          self.class.fingerprint(current) == self.class.fingerprint(fresh) &&
          ActiveSupport::SecurityUtils.secure_compare(self.class.fingerprint(fresh), @claims["fingerprint"].to_s)
        raise Invalid, "Sophtron selection changed; open the picker again"
      end
      current
    end
  end

  def self.fingerprint(item)
    Digest::SHA256.hexdigest(JSON.generate([ item.discovery_identity_fingerprint,
      item.institution_id, item.current_job_id, item.scheduled_for_deletion ]))
  end

  def self.verifier
    Rails.application.message_verifier(PURPOSE)
  end
  private_class_method :verifier
end
