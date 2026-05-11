class BrexItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  BLANK_TOKEN_SENTINELS = [ "", " ", "  ", "   ", "\t", "\n", "\r" ].freeze

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :token, deterministic: true
    encrypts :raw_payload
  end

  validates :name, presence: true
  validates :token, presence: true, on: :create
  validate :base_url_must_be_official_brex_url
  validate :token_cannot_be_blank_when_changed
  before_validation :normalize_token
  before_validation :normalize_base_url

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :brex_accounts, dependent: :destroy
  has_many :accounts, through: :brex_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }
  scope :with_credentials, -> { where.not(token: [ nil, *BLANK_TOKEN_SENTINELS ]).where("BTRIM(token) <> ''") }

  def self.resolve_for(family:, brex_item_id: nil)
    normalized_id = brex_item_id.to_s.strip.presence

    if normalized_id.present?
      return family.brex_items.active.with_credentials.find_by(id: normalized_id)
    end

    credentialed_items = family.brex_items.active.with_credentials.ordered
    credentialed_items.first if credentialed_items.one?
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_brex_data(sync_start_date: nil)
    provider = brex_provider
    unless provider
      Rails.logger.error "BrexItem #{id} - Cannot import: provider is not configured"
      raise Provider::Brex::BrexError.new("Brex provider is not configured", :not_configured)
    end

    BrexItem::Importer.new(self, brex_provider: provider, sync_start_date: sync_start_date).import
  rescue => e
    Rails.logger.error "BrexItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if brex_accounts.empty?

    results = []
    brex_accounts.joins(:account).includes(:account).merge(Account.visible).each do |brex_account|
      begin
        result = BrexAccount::Processor.new(brex_account).process
        results << { brex_account_id: brex_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "BrexItem #{id} - Failed to process account #{brex_account.id}: #{e.message}"
        results << { brex_account_id: brex_account.id, success: false, error: e.message }
      end
    end

    results
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
        Rails.logger.error "BrexItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_brex_snapshot!(accounts_snapshot)
    update!(raw_payload: BrexAccount.sanitize_payload(accounts_snapshot))
  end

  def has_completed_initial_setup?
    # Setup is complete if we have any linked accounts
    accounts.any?
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      I18n.t("brex_items.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("brex_items.sync_status.all_synced", count: linked_count)
    else
      I18n.t("brex_items.sync_status.partial_setup", synced: linked_count, pending: unlinked_count)
    end
  end

  def linked_accounts_count
    brex_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    brex_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    brex_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    brex_accounts.where.not(institution_metadata: nil)
                 .pluck(:institution_metadata)
                 .compact
                 .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("brex_items.institution_summary.none")
    when 1
      name = institutions.first["name"] ||
             institutions.first["institution_name"] ||
             I18n.t("brex_items.institution_summary.count", count: 1)
      I18n.t("brex_items.institution_summary.one", name: name)
    else
      I18n.t("brex_items.institution_summary.count", count: institutions.count)
    end
  end

  def credentials_configured?
    token.to_s.strip.present?
  end

  def effective_base_url
    return Provider::Brex::DEFAULT_BASE_URL if base_url.blank?

    Provider::Brex.normalize_base_url(base_url)
  end

  private
    def normalize_token
      self.token = token&.strip
    end

    def token_cannot_be_blank_when_changed
      return unless persisted? && will_save_change_to_token? && token.blank?

      errors.add(:token, :blank)
    end

    def normalize_base_url
      stripped = base_url.to_s.strip
      if stripped.blank?
        self.base_url = nil
        return
      end

      normalized = Provider::Brex.normalize_base_url(stripped)
      self.base_url = normalized if normalized.present?
    end

    def base_url_must_be_official_brex_url
      return if base_url.blank? || Provider::Brex.allowed_base_url?(base_url)

      errors.add(:base_url, :official_hosts_only)
    end
end
