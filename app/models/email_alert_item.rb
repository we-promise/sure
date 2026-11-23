# frozen_string_literal: true

class EmailAlertItem < ApplicationRecord
  include Syncable, Unlinking, Encryptable, DestroyableLater, ProviderDisconnectable

  # Set to true once this provider implements removal of the data it imported, so
  # a client may disconnect with disposition "discard". Left false until then:
  # the capability is advertised to API clients, and claiming it without the
  # implementation would tell a family their data was deleted when it was not.
  # See Unlinking#unlink_all! and Financekit::Purge for the worked example.
  self.supports_discard = false

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Encrypt sensitive credentials and raw provider payloads if ActiveRecord
  # encryption is configured
  if encryption_ready?
    encrypts :inbound_token, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  validates :name, presence: true
  validates :inbound_token, presence: true

  before_validation :generate_inbound_token, on: :create

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :email_alert_accounts, dependent: :destroy
  has_many :accounts, through: :email_alert_accounts
  has_many :email_alert_messages, dependent: :destroy

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }
  # Family::Syncer discovers provider items reflectively and calls `syncable` on every
  # `*_items` association whose model includes Syncable. Omitting this scope breaks the
  # whole nightly family sync, not just this provider.
  scope :syncable, -> { active }

  def syncer
    EmailAlertItem::Syncer.new(self)
  end


  # Email alerts are pushed rather than pulled: a sync processes messages that
  # are still pending, failed transiently, or arrived before their account was
  # linked.
  def import_latest_email_alert_data(sync: nil)
    email_alert_messages.retryable.order(:received_at).find_each(&:process!)
  end

  def inbound_path
    Rails.application.routes.url_helpers.webhooks_email_alerts_path(token: inbound_token)
  end

  # Invalidates the current inbound URL, e.g. after it leaked.
  def regenerate_inbound_token!
    update!(inbound_token: self.class.new_inbound_token)
  end

  def self.new_inbound_token
    SecureRandom.base58(32)
  end

  # Process linked accounts after data import
  def process_accounts
    return [] if email_alert_accounts.empty?

    results = []
    linked_email_alert_accounts.includes(account_provider: :account).each do |email_alert_account|
      begin
        result = EmailAlertAccount::Processor.new(email_alert_account).process
        results << { email_alert_account_id: email_alert_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "EmailAlertItem #{id} - Failed to process account #{email_alert_account.id}: #{e.message}"
        results << { email_alert_account_id: email_alert_account.id, success: false, error: e.message }
      end
    end

    results
  end

  # Schedule sync jobs for all linked accounts
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
        Rails.logger.error "EmailAlertItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  # Linked accounts (have AccountProvider association)
  def linked_email_alert_accounts
    email_alert_accounts.joins(:account_provider)
  end

  # Unlinked accounts (no AccountProvider association)
  def unlinked_email_alert_accounts
    email_alert_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      I18n.t("email_alert_items.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("email_alert_items.sync_status.synced", count: linked_count)
    else
      I18n.t("email_alert_items.sync_status.synced_with_setup", linked: linked_count, unlinked: unlinked_count)
    end
  end

  def linked_accounts_count
    email_alert_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    email_alert_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    email_alert_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    email_alert_accounts.includes(:account)
                  .where.not(institution_metadata: nil)
                  .map { |acc| acc.institution_metadata }
                  .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("email_alert_items.institution_summary.none")
    else
      I18n.t("email_alert_items.institution_summary.count", count: institutions.count)
    end
  end

  def credentials_configured?
    inbound_token.present?
  end

  private

    def generate_inbound_token
      self.inbound_token ||= self.class.new_inbound_token
    end
end
