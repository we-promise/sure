# frozen_string_literal: true

class WiseItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater

  SCA_PRIVATE_KEY_ATTRIBUTE = "sca_private_key"

  # Raised whenever a build starts storing rows an earlier build dropped or
  # routing stored rows to other balances: coverage an older build recorded
  # claims rows it did not keep, so every install then fetches its whole
  # history once more (WiseItem::Importer#window_start).
  COVERAGE_VERSION = 1

  # How often a family zone tzdata does not know is reported (#time_zone):
  # every balance's processing asks for it on every sync.
  UNKNOWN_TIME_ZONE_LOG_INTERVAL = 1.day

  # Raised rather than returned so no caller can mistake "not stored" for
  # "stored"; the controller turns it into the same panel error as any other
  # keypair failure.
  class SCAEncryptionUnavailable < StandardError; end

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good
  enum :profile_type, { personal: "personal", business: "business" }

  if encryption_ready?
    encrypts :token, deterministic: true
    encrypts :raw_payload
    encrypts :sca_private_key
  end

  validates :name, :profile_id, :profile_type, presence: true
  validates :token, presence: true, on: :create
  validates :profile_id, uniqueness: { scope: :family_id }

  # An SCA private key signs balance-statement requests to Wise, so plaintext
  # at rest is not an acceptable degraded mode the way an unencrypted display
  # name would be. Without ActiveRecord encryption configured, `encrypts` above
  # never runs and the PEM would land in the column as-is, so the key is simply
  # refused instead.
  validate :sca_private_key_requires_encryption

  before_validation :normalize_token

  belongs_to :family

  has_many :wise_accounts, dependent: :destroy
  has_many :accounts, through: :wise_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def import_latest_wise_data(sync_start_date: nil)
    provider = wise_provider
    unless provider
      Rails.logger.error "WiseItem #{id} - Cannot import: provider not configured"
      raise Provider::Wise::WiseError.new("Wise provider is not configured", :not_configured)
    end

    WiseItem::Importer.new(self, wise_provider: provider, sync_start_date: sync_start_date).import
  rescue => e
    Rails.logger.error "WiseItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  # import_complete: whether this sync's import fetched every source in full
  # (see WiseItem::Importer#import). Steps that delete or rewrite entries
  # only run when it is true.
  def process_accounts(import_complete: false)
    return [] if wise_accounts.empty?

    results = []
    wise_accounts.joins(:account).merge(Account.visible).each do |wise_account|
      begin
        result = WiseAccount::Processor.new(wise_account, import_complete: import_complete).process
        results << { wise_account_id: wise_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "WiseItem #{id} - Failed to process account #{wise_account.id}: #{e.message}"
        results << { wise_account_id: wise_account.id, success: false, error: e.message }
      end
    end

    results
  end

  # Links each conversion and Jar move between this item's balances as a
  # confirmed Transfer with transfer kinds (see WiseItem::InterbalanceLinker).
  def link_jar_transfers!
    WiseItem::InterbalanceLinker.new(self).link!
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    results = []
    accounts.visible.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "WiseItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  # For a balance the user has just linked to a Sure account. A sync in flight
  # picked the accounts it processes before the link existed, and sync_later
  # would only reuse it, so the balance then gets processing of its own.
  def sync_linked_account_later(wise_account)
    if syncing?
      WiseItem::ProcessLinkedAccountJob.perform_later(wise_account)
    else
      sync_later
    end
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  # Sure's own sync bookkeeping (fetch coverage, the multi-currency account)
  # lives in raw_payload, which Wise never fills.
  def sync_metadata
    raw_payload.is_a?(Hash) ? raw_payload : {}
  end

  def merge_sync_metadata!(attributes)
    update!(raw_payload: sync_metadata.merge(attributes.deep_stringify_keys))
  end

  # The window successful fetches of `source` (:transfers or :activities)
  # have covered without a gap, as { from:, through: } UTC times, or nil
  # before the first one and when an older build recorded it
  # (COVERAGE_VERSION). `through` is when the latest fetch started.
  def fetch_coverage(source)
    coverage = sync_metadata["coverage"]
    window = coverage[source.to_s] if coverage.is_a?(Hash)
    return nil unless window.is_a?(Hash) && window["version"].to_i >= COVERAGE_VERSION

    from, through = window.values_at("from", "through").map do |time|
      ActiveSupport::TimeZone["UTC"].parse(time.to_s) if time.present?
    end
    { from: from, through: through } if from && through
  rescue ArgumentError
    nil
  end

  # The zone Wise movements are dated in: the family's, or UTC when it has
  # none or one tzdata does not know. Family checks its zone only when it
  # changes, so one stored before that check (or one tzdata dropped later)
  # can stay; it is reported (#log_unknown_time_zone) rather than failing
  # every row.
  def time_zone
    @time_zone ||= begin
      requested = family&.timezone.presence
      ActiveSupport::TimeZone[requested || "UTC"] || begin
        log_unknown_time_zone(requested)
        ActiveSupport::TimeZone["UTC"]
      end
    end
  end

  # The profile's own recipients: the account recipient (the multi-currency
  # account's, kept on every balance as recipient_id) and each balance's own
  # account details (recipientId), closed balances included. A transfer into
  # one of them is a pay-in, not a payout (WiseEntry::Processor.direction).
  def own_recipient_ids
    multi_currency_account = sync_metadata["multi_currency_account"]
    ids = [ (multi_currency_account["recipientId"] if multi_currency_account.is_a?(Hash)) ]
    balance_snapshots.each do |wise_account|
      payload = wise_account.raw_payload
      ids.concat(payload.values_at("recipient_id", "recipientId")) if payload.is_a?(Hash)
    end
    ids.compact_blank.map(&:to_s).uniq
  end

  # Each balance's own account details (recipientId) => the ids of the
  # WiseAccounts holding them, closed balances included: a pay-in into them
  # reaches that balance only (WiseEntry::Processor.balance_route).
  def balance_recipient_owners
    balance_snapshots.each_with_object({}) do |wise_account, owners|
      recipient = wise_account.raw_payload["recipientId"] if wise_account.raw_payload.is_a?(Hash)
      (owners[recipient.to_s] ||= []) << wise_account.id if recipient.present?
    end
  end

  def credentials_configured?
    token.to_s.strip.present?
  end

  # True only when there's a private key AND it actually parses -- a stored
  # key that's corrupted or unparsable (e.g. an encryption misconfig or a
  # manual DB edit) should fall back to the "not configured" UI state rather
  # than rendering a blank public key box.
  def sca_configured?
    sca_public_key.present?
  end

  # Generates a new RSA keypair for Wise's Strong Customer Authentication (SCA)
  # flow, used to sign the one-time-token challenge on the balance-statement
  # endpoint. The private key stays here (encrypted at rest); the public key
  # must be registered with Wise by the user (Settings > API tokens > Public keys).
  def generate_sca_keypair!
    raise SCAEncryptionUnavailable, "Active Record encryption is not configured" unless sca_encryption_available?

    key = OpenSSL::PKey::RSA.generate(2048)
    update!(sca_private_key: key.to_pem)
    sca_public_key
  end

  def sca_encryption_available?
    self.class.encryption_ready? &&
      Array(self.class.encrypted_attributes).map(&:to_s).include?(SCA_PRIVATE_KEY_ATTRIBUTE)
  end

  def sca_public_key
    return nil unless sca_private_key.present?

    OpenSSL::PKey::RSA.new(sca_private_key).public_key.to_pem
  rescue OpenSSL::PKey::RSAError
    nil
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total == 0
      I18n.t("wise_items.sync_status.no_accounts")
    elsif unlinked == 0
      I18n.t("wise_items.sync_status.all_synced", count: linked)
    else
      I18n.t("wise_items.sync_status.partial_setup", synced: linked, pending: unlinked)
    end
  end

  def linked_accounts_count
    wise_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    wise_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    wise_accounts.count
  end

  def institution_display_name
    "Wise"
  end

  def wise_provider
    return nil unless credentials_configured?

    Provider::Wise.new(token.to_s.strip, base_url: Rails.configuration.x.wise.base_url, sca_private_key: sca_private_key)
  end

  private

    # Every balance's id and snapshot, without its stored rows: those are the
    # whole history, and processing asks for the recipients once per balance.
    def balance_snapshots
      wise_accounts.select(:id, :raw_payload)
    end

    def normalize_token
      self.token = token&.strip
    end

    # Once per interval for a family and value, the way Localize reports a
    # zone it cannot use (an atomic write that only one caller wins).
    def log_unknown_time_zone(requested)
      lease = Rails.cache.write([ "wise_unknown_family_timezone", family_id, requested ], true,
                                expires_in: UNKNOWN_TIME_ZONE_LOG_INTERVAL, unless_exist: true)
      return unless lease

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "WiseItem - Unknown family time zone #{requested.inspect}; Wise movements are dated in UTC",
        source: self.class.name,
        provider_key: "wise",
        family: family,
        metadata: { wise_item_id: id, operation: "time_zone" }
      )
    rescue StandardError => e
      Rails.logger.warn "WiseItem - Failed to capture Wise debug log: #{e.message}"
    end

    # Scoped to writes of the key itself. An install that generated a key
    # before this validation existed still has that value in the column, so
    # validating on every save would reject every later write to the record,
    # such as renaming the connection. (DestroyableLater sets the deletion flag
    # with update_column, so deleting it no longer depends on this.) Refusing a
    # NEW key is the point; refusing to let go of an old one is not.
    def sca_private_key_requires_encryption
      return unless will_save_change_to_sca_private_key?
      return if sca_private_key.blank? || sca_encryption_available?

      errors.add(:sca_private_key, :encryption_unavailable)
    end
end
