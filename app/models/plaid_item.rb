class PlaidItem < ApplicationRecord
  include Syncable, Provided, Encryptable

  enum :plaid_region, { us: "us", eu: "eu" }
  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Encrypt sensitive credentials and raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :access_token, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  validates :name, presence: true
  validates :access_token, presence: true, on: :create

  before_destroy :remove_plaid_item

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :plaid_accounts, dependent: :destroy
  has_many :legacy_accounts, through: :plaid_accounts, source: :account

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  # Get accounts from both new and legacy systems
  def accounts
    # Preload associations to avoid N+1 queries
    plaid_accounts
      .includes(:account, account_provider: :account)
      .map(&:current_account)
      .compact
      .uniq
  end

  def get_update_link_token(webhooks_url:, redirect_url:)
    family.get_link_token(
      webhooks_url: webhooks_url,
      redirect_url: redirect_url,
      region: plaid_region,
      access_token: access_token
    )
  rescue Plaid::ApiError => e
    error_body = JSON.parse(e.response_body)

    if error_body["error_code"] == "ITEM_NOT_FOUND"
      # Mark the connection as invalid but don't auto-delete
      update!(status: :requires_update)
    end

    Sentry.capture_exception(e)
    nil
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_plaid_data
    PlaidItem::Importer.new(self, plaid_provider: plaid_provider).import
  end

  # Reads the fetched data and updates internal domain objects
  # Generally, this should only be called within a "sync", but can be called
  # manually to "re-sync" the already fetched data
  def process_accounts
    plaid_accounts.each do |plaid_account|
      PlaidAccount::Processor.new(plaid_account).process
    end
  end

  # Once all the data is fetched, we can schedule account syncs to calculate historical balances
  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.each do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end

  # Saves the raw data fetched from Plaid API for this item
  def upsert_plaid_snapshot!(item_snapshot)
    assign_attributes(
      available_products: item_snapshot.available_products,
      billed_products: item_snapshot.billed_products,
      raw_payload: item_snapshot,
    )

    save!
  end

  # Saves the raw data fetched from Plaid API for this item's institution
  def upsert_plaid_institution_snapshot!(institution_snapshot)
    assign_attributes(
      institution_id: institution_snapshot.institution_id,
      institution_url: institution_snapshot.url,
      institution_color: institution_snapshot.primary_color,
      raw_institution_payload: institution_snapshot
    )

    save!
  end

  def supports_product?(product)
    supported_products.include?(product)
  end

  private
    def remove_plaid_item
      return unless plaid_provider.present?

      plaid_provider.remove_item(access_token)
    rescue Plaid::ApiError => e
      json_response = JSON.parse(e.response_body)
      error_code = json_response["error_code"]

      # Continue with deletion if:
      # - ITEM_NOT_FOUND: Item was already deleted by the user on their Plaid portal OR by Plaid support
      # - INVALID_API_KEYS: API credentials are invalid/missing, so we can't communicate with Plaid anyway
      # - Other credential errors: We're deleting our record, so no need to fail if we can't reach Plaid
      ignorable_errors = %w[ITEM_NOT_FOUND INVALID_API_KEYS INVALID_CLIENT_ID INVALID_SECRET]

      unless ignorable_errors.include?(error_code)
        # Log the error but don't prevent deletion - we're removing the item from our database
        # If we can't tell Plaid, we'll at least stop using it on our end
        Rails.logger.warn("Failed to remove Plaid item: #{error_code} - #{json_response['error_message']}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end
    end

    # Plaid returns mutually exclusive arrays here.  If the item has made a request for a product,
    # it is put in the billed_products array.  If it is supported, but not yet used, it goes in the
    # available_products array.
    def supported_products
      available_products + billed_products
    end
end
