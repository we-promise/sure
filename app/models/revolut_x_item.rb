# frozen_string_literal: true

class RevolutXItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater

  API_KEY_FORMAT = /\A[A-Za-z0-9]{64}\z/

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :private_key
    encrypts :raw_payload
  end

  validates :name, presence: true
  validates :api_key, format: { with: API_KEY_FORMAT }, allow_blank: true
  validate :private_key_must_be_ed25519

  belongs_to :family

  has_many :revolut_x_accounts, dependent: :destroy
  has_many :accounts, through: :revolut_x_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  # The keypair exists from creation; the API key arrives only once the user
  # has registered the public key with Revolut X, and until then there is
  # nothing to sync.
  scope :syncable, -> { active.where.not(api_key: [ nil, "" ]).where.not(private_key: nil) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  before_validation :strip_api_key
  # In a callback rather than a controller, so every way of creating a
  # connection ends up with a key the user can register.
  before_validation :generate_private_key, on: :create

  def import_latest_revolut_x_data
    provider = revolut_x_provider
    raise StandardError, "Revolut X credentials not configured" unless provider

    RevolutXItem::Importer.new(self, revolut_x_provider: provider).import
  rescue StandardError => e
    Rails.logger.error "RevolutXItem #{id} - Failed to import: #{e.full_message}"
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Revolut X import failed: #{e.message}",
      source: self.class.name,
      provider_key: "revolut_x",
      family: family,
      metadata: { revolut_x_item_id: id, error_class: e.class.name }
    )
    raise
  end

  def process_accounts
    return [] if revolut_x_accounts.empty?

    revolut_x_accounts.joins(:account).merge(Account.visible).map do |revolut_x_account|
      result = RevolutXAccount::Processor.new(revolut_x_account).process
      { revolut_x_account_id: revolut_x_account.id, success: true, result: result }
    rescue StandardError => e
      Rails.logger.error "RevolutXItem #{id} - Failed to process account #{revolut_x_account.id}: #{e.full_message}"
      { revolut_x_account_id: revolut_x_account.id, success: false, error: e.message }
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    accounts.visible.map do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
      { account_id: account.id, success: true }
    rescue StandardError => e
      Rails.logger.error "RevolutXItem #{id} - Failed to schedule sync for account #{account.id}: #{e.full_message}"
      { account_id: account.id, success: false, error: e.message }
    end
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total.zero?
      I18n.t("revolut_x_items.revolut_x_item.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("revolut_x_items.revolut_x_item.sync_status.all_synced", count: linked)
    else
      I18n.t("revolut_x_items.revolut_x_item.sync_status.partial_sync", linked_count: linked, unlinked_count: unlinked)
    end
  end

  def linked_accounts_count
    revolut_x_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    revolut_x_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    revolut_x_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def credentials_configured?
    api_key.present? && signing_key.present?
  end

  # The public half the user registers with Revolut X to get an API key.
  def public_key_pem
    signing_key&.public_to_pem
  end

  # The only fiat/crypto classifier: Revolut X's own asset_type when the
  # currency is listed (it lists only a few fiats), otherwise fiat iff
  # config/currencies.yml has the code with an ISO numeric. Crypto entries
  # there have a blank iso_numeric, as do a few non-ISO fiats (CNH, GBX,
  # GGP, IMP, JEP, XFU), which are therefore treated as non-fiat.
  def fiat_currency?(code)
    code = code.to_s.upcase
    listed = raw_payload.is_a?(Hash) ? raw_payload.dig("currencies", code) : nil
    asset_type = listed["asset_type"] if listed.is_a?(Hash)
    return asset_type == "fiat" if asset_type.present?

    Money::Currency.all.dig(code.downcase, "iso_numeric").present?
  end

  def set_revolut_x_institution_defaults!
    update!(
      institution_name: "Revolut X",
      institution_domain: "revolut.com",
      institution_url: "https://exchange.revolut.com",
      institution_color: "#111827"
    )
  end

  private

    # The stored key parsed, or nil when it is missing or not Ed25519.
    def signing_key
      return nil if private_key.blank?

      # The empty passphrase makes an encrypted key fail to parse instead of
      # OpenSSL prompting for one on the server's terminal.
      key = OpenSSL::PKey.read(private_key, "")
      key.private_to_der # raises for a public-only key, which cannot sign
      key if key.oid == "ED25519"
    rescue OpenSSL::PKey::PKeyError
      nil
    end

    def strip_api_key
      self.api_key = api_key.strip if api_key_changed? && api_key.is_a?(String)
    end

    def generate_private_key
      self.private_key = OpenSSL::PKey.generate_key("ED25519").private_to_pem if private_key.blank?
    end

    def private_key_must_be_ed25519
      errors.add(:private_key, :invalid) unless signing_key
    end
end
