class AkahuItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :app_token, deterministic: true
    encrypts :user_token, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later
  has_many :akahu_accounts, dependent: :destroy
  has_many :accounts, through: :akahu_accounts

  validates :name, presence: true
  validates :app_token, :user_token, presence: true, on: :create

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_akahu_data
    provider = akahu_provider
    unless provider
      Rails.logger.error "AkahuItem #{id} - Cannot import: Akahu provider is not configured"
      raise StandardError.new("Akahu provider is not configured")
    end

    AkahuItem::Importer.new(self, akahu_provider: provider).import
  rescue => e
    Rails.logger.error "AkahuItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if akahu_accounts.empty?

    akahu_accounts.joins(:account).merge(Account.visible).map do |akahu_account|
      result = AkahuAccount::Processor.new(akahu_account).process
      if result.is_a?(Hash) && result.with_indifferent_access[:success] == false
        { akahu_account_id: akahu_account.id, success: false, error: I18n.t("akahu_item.errors.account_processing_failed") }
      else
        { akahu_account_id: akahu_account.id, success: true, result: result }
      end
    rescue => e
      Rails.logger.error "AkahuItem #{id} - Failed to process account #{akahu_account.id}: #{e.class} - #{e.message}"
      { akahu_account_id: akahu_account.id, success: false, error: I18n.t("akahu_item.errors.account_processing_failed") }
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
    rescue => e
      Rails.logger.error "AkahuItem #{id} - Failed to schedule sync for account #{account.id}: #{e.class} - #{e.message}"
      { account_id: account.id, success: false, error: I18n.t("akahu_item.errors.account_sync_schedule_failed") }
    end
  end

  def upsert_akahu_snapshot!(accounts_snapshot)
    assign_attributes(raw_payload: accounts_snapshot)
    save!
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts.zero?
      I18n.t("akahu_item.sync_status.no_accounts")
    elsif unlinked_count.zero?
      I18n.t("akahu_item.sync_status.all_synced", count: linked_count)
    else
      I18n.t("akahu_item.sync_status.partial", linked: linked_count, unlinked: unlinked_count)
    end
  end

  def linked_accounts_count
    akahu_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    akahu_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    akahu_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    akahu_accounts.includes(:account)
                  .where.not(institution_metadata: nil)
                  .map(&:institution_metadata)
                  .uniq { |inst| inst["id"] || inst["name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("akahu_item.institution_summary.none")
    when 1
      institutions.first["name"].presence || I18n.t("akahu_item.institution_summary.one")
    else
      I18n.t("akahu_item.institution_summary.count", count: institutions.count)
    end
  end

  def credentials_configured?
    app_token.present? && user_token.present?
  end
end
