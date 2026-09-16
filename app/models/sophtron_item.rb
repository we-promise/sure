# Represents a Sophtron integration item for a family.
#
# A SophtronItem stores Sophtron API credentials and manages the connection
# to a family's Sophtron account. It can have multiple associated SophtronAccounts,
# which represent individual bank accounts linked through Sophtron.
#
# @attr [String] name The display name for this Sophtron connection
# @attr [String] user_id Sophtron User ID (encrypted if encryption is configured)
# @attr [String] access_key Sophtron Access Key (encrypted if encryption is configured)
# @attr [String] base_url Base URL for Sophtron API (optional, defaults to production)
# @attr [String] status Current status: 'good' or 'requires_update'
# @attr [Boolean] scheduled_for_deletion Whether the item is scheduled for deletion
# @attr [DateTime] last_synced_at When the last successful sync occurred
class SophtronItem < ApplicationRecord
  include Syncable, Provided, Unlinking, LegacyWriterGuard

  INITIAL_LOAD_LOOKBACK_DAYS = 120
  MAX_TRANSACTION_HISTORY_YEARS = 3

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Helper to detect if ActiveRecord Encryption is configured for this app.
  #
  # Checks both Rails credentials and environment variables for encryption keys.
  #
  # @return [Boolean] true if encryption is properly configured
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  # Encrypt sensitive credentials if ActiveRecord encryption is configured (credentials OR env vars)
  if encryption_ready?
    encrypts :user_id, deterministic: true
    encrypts :access_key, deterministic: true
  end

  validates :name, presence: true
  validates :user_id, presence: true, on: :create
  validates :access_key, presence: true, on: :create

  belongs_to :family
  belongs_to :current_job_sophtron_account, class_name: "SophtronAccount", optional: true
  has_one_attached :logo

  has_many :sophtron_accounts, dependent: :destroy
  has_many :accounts, through: :sophtron_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    SophtronItem::LegacyAccess.with_item(self, operation: :lifecycle) do |current|
      current.update!(scheduled_for_deletion: true)
      DestroyJob.perform_later(current)
    end
  end

  # Admission precedes Active Record's destruction transaction and remains held
  # through dependent Sophtron accounts. Generic unfenced parent transactions
  # fail closed until their caller adopts an operation boundary.
  def destroy
    return super if new_record? || destroyed?

    SophtronItem::LegacyAccess.with_item(self, operation: :lifecycle) do |current|
      results = current.unlink_all!
      if results.any? { |result| result[:error].present? }
        raise ActiveRecord::RecordNotDestroyed.new("Sophtron links could not be removed", self)
      end
      reload
      super
    end
  end

  # Imports the latest account and transaction data from Sophtron.
  #
  # This method fetches all accounts and transactions from the Sophtron API
  # and updates the local database accordingly. It will:
  # - Fetch all accounts associated with the Sophtron connection
  # - Create new SophtronAccount records for newly discovered accounts
  # - Update existing linked accounts with latest data
  # - Fetch and store transactions for all linked accounts
  #
  # @return [Hash] Import results with counts of accounts and transactions imported
  # @raise [StandardError] if the Sophtron provider is not configured
  # @raise [Provider::Sophtron::Error] if the Sophtron API returns an error
  def import_latest_sophtron_data(sync: nil)
    SophtronItem::Importer.new(self, sync: sync).import
  rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged, Provider::AccountData::LegacyWriterFence::InvalidSource
    raise
  rescue => e
    Rails.logger.error "SophtronItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def linked_visible_sophtron_accounts
    sophtron_accounts.joins(:account).merge(Account.visible)
  end

  def automatic_sync_sophtron_accounts
    return linked_visible_sophtron_accounts.none if manual_sync?

    linked_visible_sophtron_accounts.automatic_sync
  end

  def manual_sync_required?
    manual_sync? || sophtron_accounts.requires_manual_sync.exists?
  end

  def manual_sync_sophtron_accounts
    linked_accounts = sophtron_accounts.joins(:account_provider).order(:created_at, :id)
    manual_accounts = linked_accounts.requires_manual_sync

    return manual_accounts if manual_accounts.exists?

    manual_sync? ? linked_accounts : linked_accounts.none
  end

  def connected_institution_options
    sophtron_accounts.order(:created_at, :id).filter_map do |sophtron_account|
      institution_key = sophtron_account.institution_key
      next if institution_key.blank?

      {
        institution_key: institution_key,
        name: sophtron_account.institution_name.presence || institution_display_name
      }
    end.uniq { |institution| institution[:institution_key].to_s }
  end

  def manual_sync_required_for_institution?(institution_key)
    institution_accounts = sophtron_accounts.select do |sophtron_account|
      sophtron_account.institution_key.to_s == institution_key.to_s
    end

    return manual_sync? if institution_accounts.empty?

    institution_accounts.any?(&:manual_sync?) || (manual_sync? && !sophtron_accounts.requires_manual_sync.exists?)
  end

  def process_accounts(sophtron_accounts_scope: linked_visible_sophtron_accounts, sync: nil)
    sync = Provider::AccountData::LegacyWriterFence.scoped_sync!(self, sync)
    sophtron_accounts_scope = Provider::AccountData::LegacyWriterFence.scoped_accounts!(self, sophtron_accounts_scope)
    return [] if sophtron_accounts_scope.empty?

    results = []
    # Only process accounts that are linked and have active status
    sophtron_accounts_scope.each do |sophtron_account|
      begin
        processor = sync ? SophtronAccount::Processor.new(sophtron_account, sync: sync) : SophtronAccount::Processor.new(sophtron_account)
        result = processor.process
        results << { sophtron_account_id: sophtron_account.id, success: true, result: result }
      rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged, Provider::AccountData::LegacyWriterFence::InvalidSource
        raise
      rescue => e
        Rails.logger.error "SophtronItem #{id} - Failed to process account #{sophtron_account.id}: #{e.message}"
        results << { sophtron_account_id: sophtron_account.id, success: false, error: e.message }
        # Continue processing other accounts even if one fails
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil, sophtron_accounts_scope: linked_visible_sophtron_accounts, allow_completed: false)
    parent_sync = Provider::AccountData::LegacyWriterFence.scoped_sync!(self, parent_sync, allow_completed: allow_completed)
    selected = Provider::AccountData::LegacyWriterFence.scoped_accounts!(self, sophtron_accounts_scope)
    return [] if selected.empty?

    results = []
    # Only schedule syncs for active accounts
    selected.each do |source_account|
      parent_sync = Provider::AccountData::LegacyWriterFence.scoped_sync!(self, parent_sync, allow_completed: allow_completed)
      current = Provider::AccountData::LegacyWriterFence.scoped_accounts!(self, [ source_account ]).sole
      account = current.current_account
      next unless account
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged, Provider::AccountData::LegacyWriterFence::InvalidSource
        raise
      rescue => e
        Rails.logger.error "SophtronItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
        # Continue scheduling other accounts even if one fails
      end
    end

    results
  end

  def start_initial_load_later
    active_sync = syncs.visible.ordered.first

    sync_later(window_start_date: initial_load_window_start_date)

    return unless active_sync&.reload&.syncing?

    SophtronInitialLoadJob.set(wait: SophtronInitialLoadJob::RETRY_DELAY).perform_later(self)
  end

  def initial_load_window_start_date
    configured_start = sync_start_date&.to_date
    default_start = INITIAL_LOAD_LOOKBACK_DAYS.days.ago.to_date
    max_history_start = MAX_TRANSACTION_HISTORY_YEARS.years.ago.to_date

    [ configured_start || default_start, max_history_start ].max
  end

  def upsert_sophtron_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def ensure_customer!
    SophtronItem::LegacyAccess.with_item(self, operation: :credentials) do |current, _sync|
      result = current.send(:ensure_customer_admitted!)
      reload unless current.equal?(self)
      result
    end
  end

  def verify_and_provision_customer
    SophtronItem::LegacyAccess.with_item(self, operation: :credentials) do |current, _sync|
      result = current.send(:verify_and_provision_customer_admitted)
      reload unless current.equal?(self)
      result
    end
  end

  def connected_to_institution?
    user_institution_id.present? && current_job_id.blank? && good? && !failed_connection_job?
  end

  def failed_connection_job?
    payload = raw_job_payload || {}
    payload = payload.with_indifferent_access if payload.respond_to?(:with_indifferent_access)

    success_flag = if payload.respond_to?(:key?) && payload.key?(:SuccessFlag)
      payload[:SuccessFlag]
    elsif payload.respond_to?(:key?)
      payload[:success_flag]
    end

    last_status = job_status.presence ||
      (payload[:LastStatus] if payload.respond_to?(:[])) ||
      (payload[:last_status] if payload.respond_to?(:[]))

    success_flag == false && Provider::Sophtron.failure_job_status?(last_status)
  end

  def upsert_job_snapshot!(job_payload)
    job_payload = job_payload.with_indifferent_access

    update!(
      job_status: job_payload[:LastStatus] || job_payload[:last_status],
      raw_job_payload: job_payload
    )
  end

  def fetch_remote_accounts(force: false)
    cache_key = discovery_cache_key
    cached = Rails.cache.read(cache_key)
    return cached if cached.present? && !force

    accounts_data = Provider::Sophtron.response_data!(sophtron_provider.get_accounts(user_institution_id))
    accounts = accounts_data[:accounts] || []
    Rails.cache.write(cache_key, accounts, expires_in: 5.minutes)
    persist_remote_sophtron_accounts(accounts)
    accounts
  end

  def search_institutions(query)
    provider = sophtron_provider
    raise Provider::Sophtron::Error.new("Sophtron provider is not configured", :configuration_error) unless provider

    Provider::Sophtron.response_data!(provider.search_institutions(query))
  end

  def persist_remote_sophtron_accounts(accounts)
    Array(accounts).each do |account_data|
      account_data = account_data.with_indifferent_access
      next if account_data[:account_name].blank?

      upsert_sophtron_account(account_data)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("Skipping Sophtron account #{self.class.external_account_id(account_data)}: #{e.message}")
    end
  end

  def reject_already_linked(accounts)
    linked_account_ids = sophtron_accounts.joins(:account_provider).pluck(:account_id).map(&:to_s)
    Array(accounts).reject { |account| linked_account_ids.include?(self.class.external_account_id(account).to_s) }
  end

  def upsert_sophtron_account(account_data)
    sophtron_accounts.find_or_initialize_by(
      account_id: self.class.external_account_id(account_data).to_s
    ).tap do |sophtron_account|
      sophtron_account.upsert_sophtron_snapshot!(account_data)
    end
  end

  def build_mfa_challenge(job)
    job = job.with_indifferent_access
    {
      security_questions: Provider::Sophtron.parse_json_array(job[:SecurityQuestion] || job[:security_question]),
      token_methods: Provider::Sophtron.parse_json_array(job[:TokenMethod] || job[:token_method]),
      token_sent: Provider::Sophtron.job_token_input_required?(job),
      token_read: job[:TokenRead] || job[:token_read],
      captcha_image: job[:CaptchaImage] || job[:captcha_image]
    }
  end

  def self.external_account_id(account_data)
    account_data.with_indifferent_access[:account_id] || account_data.with_indifferent_access[:id]
  end

  def has_completed_initial_setup?
    # Setup is complete if we have any linked accounts
    accounts.any?
  end

  def sync_status_summary
    # Use centralized count helper methods for consistency
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      "No accounts found"
    elsif unlinked_count == 0
      "#{linked_count} #{'account'.pluralize(linked_count)} synced"
    else
      "#{linked_count} synced, #{unlinked_count} need setup"
    end
  end

  def linked_accounts_count
    sophtron_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    sophtron_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    sophtron_accounts.count
  end

  def institution_display_name
    # Try to get institution name from stored metadata
    institution_name.presence || institution_domain.presence || name
  end

  def provider_display_name
    I18n.t("sophtron_items.defaults.name", default: "Sophtron Connection")
  end

  def connected_institutions
    # Get unique institutions from all accounts
    sophtron_accounts.includes(:account)
                      .where.not(institution_metadata: nil)
                      .map { |acc| acc.institution_metadata }
                      .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      "No institutions connected"
    when 1
      institutions.first["name"] || institutions.first["institution_name"] || "1 institution"
    else
      "#{institutions.count} institutions"
    end
  end

  def credentials_configured?
    user_id.present? &&
    access_key.present?
  end

  def effective_base_url
    base_url.presence || Provider::Sophtron::DEFAULT_BASE_URL
  end

  # Keyed identity may be used in caches and signed form grants without exposing
  # the credentials or permitting an offline guess of their plaintext values.
  def discovery_identity_fingerprint
    key = Rails.application.key_generator.generate_key("sophtron-discovery-cache-v1", 32)
    identity = JSON.generate([ user_id, access_key, effective_base_url, customer_id, user_institution_id ])
    OpenSSL::HMAC.hexdigest("SHA256", key, identity)
  end

  def generated_customer_unique_id
    "sure-family-#{family.id}"
  end

  def generated_customer_name
    "Sure family #{family.id}"
  end

  private

    def verify_and_provision_customer_admitted
      provider = sophtron_provider
      raise Provider::Sophtron::Error.new("Sophtron provider is not configured", :configuration_error) unless provider

      Provider::Sophtron.response_data!(provider.health_check_auth)
      ensure_customer_admitted!(provider: provider)
      true
    rescue Provider::Sophtron::Error => error
      update(status: :requires_update, last_connection_error: error.message)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
        message: "Sophtron credential verification or customer provisioning failed", source: self.class.name,
        provider_key: "sophtron", family: family,
        metadata: { item_id: id, error_class: error.class.name })
      false
    end

    def ensure_customer_admitted!(provider: nil)
      return customer_id if customer_id.present?
      provider ||= sophtron_provider
      raise Provider::Sophtron::Error.new("Sophtron provider is not configured", :configuration_error) unless provider

      matching_customer = find_matching_customer(Provider::Sophtron.response_data!(provider.list_customers))
      customer_payload = matching_customer || Provider::Sophtron.response_data!(
        provider.create_customer(
          unique_id: generated_customer_unique_id,
          name: generated_customer_name,
          source: "Sure"
        )
      )
      if extract_customer_id(customer_payload).blank?
        customer_payload = find_matching_customer(Provider::Sophtron.response_data!(provider.list_customers))
      end

      extracted_customer_id = extract_customer_id(customer_payload)
      raise Provider::Sophtron::Error.new("Sophtron customer response did not include CustomerID", :invalid_response) if extracted_customer_id.blank?

      update!(
        customer_id: extracted_customer_id,
        customer_name: extract_customer_name(customer_payload).presence || generated_customer_name,
        raw_customer_payload: customer_payload
      )
      customer_id
    end

    def discovery_cache_key
      "sophtron_accounts_v2_#{family_id}_#{id}_#{discovery_identity_fingerprint}"
    end

    def find_matching_customer(customers)
      customers = Array(customers)

      customers.find do |customer|
        extract_customer_id(customer).to_s == generated_customer_unique_id
      end || customers.find do |customer|
        extract_customer_name(customer).to_s == generated_customer_name
      end
    end

    def extract_customer_id(customer_payload)
      return nil unless customer_payload.respond_to?(:with_indifferent_access)

      customer_payload = customer_payload.with_indifferent_access
      customer_payload[:CustomerID] || customer_payload[:customer_id] || customer_payload[:id]
    end

    def extract_customer_name(customer_payload)
      return nil unless customer_payload.respond_to?(:with_indifferent_access)

      customer_payload = customer_payload.with_indifferent_access
      customer_payload[:CustomerName] || customer_payload[:customer_name] || customer_payload[:name]
    end

  guard_legacy_writes import_latest_sophtron_data: :ingest, process_accounts: :publish,
    schedule_account_syncs: :publish, start_initial_load_later: :publish,
    upsert_sophtron_snapshot!: :ingest, upsert_job_snapshot!: :ingest,
    fetch_remote_accounts: :ingest, persist_remote_sophtron_accounts: :ingest,
    upsert_sophtron_account: :ingest, search_institutions: :ingest
end
