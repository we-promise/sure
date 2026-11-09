# frozen_string_literal: true

class TricountItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater, ProviderDisconnectable

  # Set to true once this provider implements removal of the data it imported, so
  # a client may disconnect with disposition "discard". Left false until then:
  # the capability is advertised to API clients, and claiming it without the
  # implementation would tell a family their data was deleted when it was not.
  # See Unlinking#unlink_all! and Financekit::Purge for the worked example.
  self.supports_discard = false

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Every tricount is Tricount's, whichever group it belongs to.
  INSTITUTION = { name: "Tricount", domain: "tricount.com", url: "https://tricount.com" }.freeze

  before_validation :assign_institution, on: :create

  # A sharing token gives read and write access to its tricount, so it is a
  # secret, as is the device's session token.
  if encryption_ready?
    encrypts :sharing_tokens
    encrypts :session_token
  end

  validates :name, presence: true
  validates :sharing_tokens, presence: true

  # The settings form's field for adding tricount links (see #add_sharing_links).
  attr_reader :sharing_links

  # The name for a new account following this tricount.
  def account_name_for(tricount_account)
    return tricount_account.name unless prefix_account_names?

    I18n.t("tricount_items.account_name_prefixed", name: tricount_account.name)
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :tricount_accounts, dependent: :destroy
  has_many :accounts, through: :tricount_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }
  # Family::Syncer discovers provider items reflectively and calls `syncable` on every
  # `*_items` association whose model includes Syncable. Omitting this scope breaks the
  # whole nightly family sync, not just this provider.
  scope :syncable, -> { active }

  def syncer
    TricountItem::Syncer.new(self)
  end


  # Import data from provider API
  def import_latest_tricount_data(sync: nil)
    provider = tricount_provider
    unless provider
      Rails.logger.error "TricountItem #{id} - Cannot import: provider is not configured"
      raise StandardError, I18n.t("tricount_items.errors.provider_not_configured")
    end

    TricountItem::Importer.new(self, tricount_provider: provider, sync: sync).import
  rescue => e
    Rails.logger.error "TricountItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  # Process linked accounts after data import
  # With `only` (the tricount ids a sync just read), the others are left as
  # they are: their snapshot is the last one read, and taking it as today's
  # balance would anchor that stale balance on today.
  def process_accounts(only: nil)
    return [] if tricount_accounts.empty?

    results = []
    # A disabled account keeps the data it has, as with the other providers.
    scope = linked_tricount_accounts.joins(account_provider: :account).merge(Account.visible).includes(account_provider: :account)
    scope = scope.where(tricount_account_id: only) unless only.nil?
    scope.each do |tricount_account|
      begin
        result = TricountAccount::Processor.new(tricount_account).process
        results << { tricount_account_id: tricount_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "TricountItem #{id} - Failed to process account #{tricount_account.id}: #{e.message}"
        results << { tricount_account_id: tricount_account.id, success: false, error: e.message }
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
        Rails.logger.error "TricountItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_tricount_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  # Linked accounts (have AccountProvider association)
  def linked_tricount_accounts
    tricount_accounts.joins(:account_provider)
  end

  # Unlinked accounts (no AccountProvider association)
  def unlinked_tricount_accounts
    tricount_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      I18n.t("tricount_items.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("tricount_items.sync_status.synced", count: linked_count)
    else
      I18n.t("tricount_items.sync_status.synced_with_setup", linked: linked_count, unlinked: unlinked_count)
    end
  end

  def linked_accounts_count
    tricount_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    tricount_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    tricount_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    tricount_accounts.includes(:account)
                  .where.not(institution_metadata: nil)
                  .map { |acc| acc.institution_metadata }
                  .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("tricount_items.institution_summary.none")
    else
      I18n.t("tricount_items.institution_summary.count", count: institutions.count)
    end
  end

  def assign_institution
    self.institution_name = INSTITUTION[:name]
    self.institution_domain = INSTITUTION[:domain]
    self.institution_url = INSTITUTION[:url]
  end

  def credentials_configured?
    sharing_tokens.present?
  end
end
