require "uri"

class Account < ApplicationRecord
  include AASM, Syncable, Monetizable, Chartable, Linkable, Enrichable, Anchorable, Reconcileable, TaxTreatable

  before_validation :assign_default_owner, if: -> { owner_id.blank? }

  before_destroy :capture_account_statement_ids_to_move
  before_destroy :cleanup_transfers

  after_destroy_commit :move_account_statements_to_inbox


  # Mark logo_source as "manual" when a logo is uploaded without an
  # explicit source selection. This ensures uploads are prioritized
  # over auto-fetched logos.
  before_save :mark_manual_if_logo_uploaded, if: -> { logo.attached? && !@attaching_fetched_logo && logo_upload_in_this_save? && !@logo_source_explicitly_set }

  # Queue logo fetch after save to avoid blocking the save operation
  after_save_commit :queue_logo_fetch, if: :should_queue_logo_fetch?
  after_save_commit :purge_manual_logo_on_auto_switch, if: :should_purge_manual_logo?
  before_validation :clean_institution_domain, if: -> { read_attribute(:institution_domain).present? }

  validates :name, :balance, :currency, presence: true
  validate :owner_belongs_to_family, if: -> { owner_id.present? && family_id.present? }
  validate :validate_logo_file, if: -> { logo.attached? }

  belongs_to :family
  belongs_to :owner, class_name: "User", optional: true
  belongs_to :import, optional: true

  has_many :account_shares, dependent: :destroy
  has_many :shared_users, through: :account_shares, source: :user
  has_many :import_mappings, as: :mappable, dependent: :destroy, class_name: "Import::Mapping"
  has_many :entries, dependent: :destroy
  has_many :transactions, through: :entries, source: :entryable, source_type: "Transaction"
  has_many :valuations, through: :entries, source: :entryable, source_type: "Valuation"
  has_many :trades, through: :entries, source: :entryable, source_type: "Trade"
  has_many :holdings, dependent: :destroy
  has_many :balances, dependent: :destroy
  has_many :recurring_transactions, dependent: :destroy
  has_many :goal_accounts, dependent: :destroy
  has_many :goals, through: :goal_accounts
  has_many :goal_pledges, dependent: :destroy
  # Inverse for recurring transfers where this account is the destination.
  # Account#recurring_transactions only matches account_id; without this
  # association, destroying the destination account would hit the FK
  # cascade silently and the AR cache wouldn't reflect the deletion.
  has_many :inbound_recurring_transfers,
           class_name: "RecurringTransaction",
           foreign_key: :destination_account_id,
           dependent: :destroy

  monetize :balance, :cash_balance

  enum :classification, { asset: "asset", liability: "liability" }, validate: { allow_nil: true }

  VISIBLE_STATUSES = %w[draft active].freeze
  HISTORICAL_STATUSES = (VISIBLE_STATUSES + %w[disabled]).freeze

  scope :visible, -> { where(status: VISIBLE_STATUSES) }
  scope :historical, -> { where(status: HISTORICAL_STATUSES) }
  # Accounts whose data should be included in financial reports, dashboards,
  # and exports. Excludes accounts where the user has opted to suppress them.
  scope :included_in_reports, -> { where(exclude_from_reports: false) }
  scope :assets, -> { where(classification: "asset") }
  scope :liabilities, -> { where(classification: "liability") }
  scope :alphabetically, -> { order(:name) }
  scope :manual, -> {
    left_joins(:account_providers)
      .where(account_providers: { id: nil })
      .where(plaid_account_id: nil, simplefin_account_id: nil)
  }

  scope :visible_manual, -> {
    visible.manual
  }

  scope :listable_manual, -> {
    manual.where.not(status: :pending_deletion)
  }

  # All accounts a user can access (owned + shared with them)
  scope :accessible_by, ->(user) {
    left_joins(:account_shares)
      .where("accounts.owner_id = :uid OR account_shares.user_id = :uid", uid: user.id)
      .distinct
  }

  # Accounts a user can write to (owned or shared with full_control)
  scope :writable_by, ->(user) {
    left_joins(:account_shares)
      .where("accounts.owner_id = :uid OR (account_shares.user_id = :uid AND account_shares.permission = 'full_control')", uid: user.id)
      .distinct
  }

  # Accounts that count in a user's financial calculations
  scope :included_in_finances_for, ->(user) {
    left_joins(:account_shares)
      .where(
        "accounts.owner_id = :uid OR " \
        "(account_shares.user_id = :uid AND account_shares.include_in_finances = true)",
        uid: user.id
      )
      .distinct
  }

  has_one_attached :logo, dependent: :purge_later

  # Upper bound for logo attachments, enforced on uploads and on fetched
  # logos in Account::LogoFetcher. Matches the other upload caps (imports,
  # account statements).
  MAX_LOGO_BYTES = 25.megabytes

  ACCEPTED_LOGO_CONTENT_TYPES = %w[
    image/avif image/bmp image/gif image/heic image/heif image/jpeg
    image/jpg image/png image/svg+xml image/tiff image/webp image/x-icon
    image/vnd.microsoft.icon
  ].freeze
  # No dependent: option; before_destroy captures IDs, after_destroy_commit moves statements back to inbox.
  has_many :account_statements

  # Track whether logo is manually uploaded or auto-fetched
  enum :logo_source, { auto: "auto", manual: "manual" }, default: "auto", prefix: :logo_source, validate: true

  # Track whether logo_source was explicitly set by the user.
  # This allows the before_save callback to distinguish between
  # "user chose auto" and "user didn't specify".
  def logo_source=(value)
    @logo_source_explicitly_set = true
    super
  end

  delegated_type :accountable, types: Accountable::TYPES, dependent: :destroy
  delegate :subtype, to: :accountable, allow_nil: true

  # Writer for subtype that delegates to the accountable, allowing forms to set
  # subtype directly on the account.
  #
  # On create the accountable is not built yet, and the chosen subtype is easy to
  # drop because of mass-assignment ordering. Two cases:
  #
  #   1. `subtype` is applied while `accountable_type` is already known — build
  #      the accountable from the delegated type so the value lands on it. The
  #      later `accountable_attributes` assignment (update_only) then updates that
  #      same record instead of building a new one.
  #   2. `subtype` is applied *before* `accountable_type` — this is the real
  #      controller path: strong-params `permit` preserves filter order, and
  #      `account_params` lists `:subtype` before `:accountable_type`, so the
  #      writer runs while the type (and thus `accountable_class`) is still
  #      unknown. We can't build the accountable yet, so stash the value and
  #      apply it from `accountable_type=` once the type is set.
  def subtype=(value)
    self.accountable = accountable_class.new if accountable.nil? && accountable_type.present?

    if accountable
      accountable.subtype = value
    else
      @deferred_subtype = value
    end
  end

  # Applies a subtype that arrived before the type was known (see `subtype=`
  # case 2). `super` resolves `accountable_type`/`accountable_class` first, then
  # the re-entrant `subtype=` builds the accountable and assigns the value.
  def accountable_type=(value)
    super

    if defined?(@deferred_subtype)
      pending = @deferred_subtype
      remove_instance_variable(:@deferred_subtype)
      self.subtype = pending
    end
  end

  accepts_nested_attributes_for :accountable, update_only: true

  # Account state machine
  aasm column: :status, timestamps: true do
    state :active, initial: true
    state :draft
    state :disabled
    state :pending_deletion

    event :activate do
      transitions from: [ :draft, :disabled ], to: :active
    end

    event :disable do
      transitions from: [ :draft, :active ], to: :disabled
    end

    event :enable do
      transitions from: :disabled, to: :active
    end

    event :mark_for_deletion do
      transitions from: [ :draft, :active, :disabled ], to: :pending_deletion
    end
  end

  class << self
    def human_attribute_name(attribute, options = {})
      options = { moniker: Current.family&.moniker_label || "Family" }.merge(options)
      super(attribute, options)
    end

    def create_and_sync(attributes, skip_initial_sync: false, opening_balance_date: nil)
      attributes[:accountable_attributes] ||= {} # Ensure accountable is created, even if empty
      # Default cash_balance to balance unless explicitly provided (e.g., Crypto sets it to 0)
      attrs = attributes.dup
      attrs[:cash_balance] = attrs[:balance] unless attrs.key?(:cash_balance)
      account = new(attrs)
      # Presence is read from the raw value: a blank form field arrives as ""
      # and would convert to a very present-looking 0.
      raw_initial_balance = attributes.dig(:accountable_attributes, :initial_balance)
      initial_balance = raw_initial_balance.to_d if raw_initial_balance.present?

      transaction do
        account.save!

        manager = Account::OpeningBalanceManager.new(account)
        result = manager.set_opening_balance(
          balance: initial_balance || account.balance,
          date: opening_balance_date
        )
        raise result.error if result.error

        # When the opening balance differs from the entered current balance
        # (a loan created with its original principal), the opening anchor is
        # the account's only entry — the initial sync would recalculate
        # today's balance back to it, silently discarding what the user just
        # typed. Anchor today's balance too so both survive.
        #
        # Only when the opening anchor is on an earlier day: the opening date
        # is user-supplied and may be today, and a same-day reconciliation
        # would be matched to the opening anchor by date and overwrite it.
        # On its own date the opening balance wins.
        if initial_balance && initial_balance != account.balance && manager.opening_date < Date.current
          # An explicit reconciliation, not CurrentBalanceManager: for cash
          # accounts its transaction-adjustment strategy computes a zero delta
          # here (account.balance already holds the entered value) and would
          # only rewrite the opening anchor, leaving today's balance unanchored
          # for the first sync.
          reconciliation = Account::ReconciliationManager.new(account).reconcile_balance(
            balance: account.balance,
            date: Date.current
          )
          raise reconciliation.error_message unless reconciliation.success?
        end

        account.auto_share_with_family! if account.family.share_all_by_default?
      end

      # Skip initial sync for linked accounts - the provider sync will handle balance creation
      # after the correct currency is known
      account.sync_later unless skip_initial_sync
      account
    end


    def create_from_simplefin_account(simplefin_account, account_type, subtype = nil)
      # Respect user choice when provided; otherwise infer a sensible default
      # Require an explicit account_type; do not infer on the backend
      if account_type.blank? || account_type.to_s == "unknown"
        raise ArgumentError, "account_type is required when creating an account from SimpleFIN"
      end

      # Get the balance from SimpleFin
      balance = simplefin_account.current_balance || simplefin_account.available_balance || 0

      # SimpleFin returns negative balances for credit cards (liabilities)
      # But Sure expects positive balances for liabilities
      if account_type == "CreditCard" || account_type == "Loan"
        balance = balance.abs
      end

      # Calculate cash balance correctly for investment accounts
      cash_balance = balance
      if account_type == "Investment"
        begin
          calculator = SimplefinAccount::Investments::BalanceCalculator.new(simplefin_account)
          calculated = calculator.cash_balance
          cash_balance = calculated unless calculated.nil?
        rescue => e
          Rails.logger.warn(
            "Investment cash_balance calculation failed for " \
            "SimpleFin account #{simplefin_account.id}: #{e.class} - #{e.message}"
          )
          # Fallback to zero as suggested
          cash_balance = 0
        end
      end

      family = simplefin_account.simplefin_item.family
      attributes = {
        family: family,
        name: simplefin_account.name,
        balance: balance,
        cash_balance: cash_balance,
        currency: simplefin_account.currency,
        accountable_type: account_type,
        accountable_attributes: build_simplefin_accountable_attributes(simplefin_account, account_type, subtype),
        simplefin_account_id: simplefin_account.id
      }

      # Skip initial sync - provider sync will handle balance creation with correct currency
      create_and_sync(attributes, skip_initial_sync: true)
    end

    def create_from_enable_banking_account(enable_banking_account, account_type, subtype = nil)
      # Get the balance from Enable Banking
      balance = enable_banking_account.current_balance || 0

      # Enable Banking may return negative balances for liabilities
      # Sure expects positive balances for liabilities
      if account_type == "CreditCard" || account_type == "Loan"
        balance = balance.abs
      end

      cash_balance = balance

      family = enable_banking_account.enable_banking_item.family
      attributes = {
        family: family,
        name: enable_banking_account.name,
        balance: balance,
        cash_balance: cash_balance,
        currency: enable_banking_account.currency || "EUR"
      }

      accountable_attributes = {}
      accountable_attributes[:subtype] = subtype if subtype.present?

      # Skip initial sync - provider sync will handle balance creation with correct currency
      create_and_sync(
        attributes.merge(
          accountable_type: account_type,
          accountable_attributes: accountable_attributes
        ),
        skip_initial_sync: true
      )
    end

    def create_from_wise_account(wise_account)
      family = wise_account.wise_item.family

      create_and_sync(
        {
          family: family,
          name: wise_account.name || "Wise #{wise_account.currency}",
          balance: wise_account.current_balance || 0,
          cash_balance: wise_account.current_balance || 0,
          currency: wise_account.currency,
          accountable_type: "Depository",
          accountable_attributes: { subtype: wise_account.account_subtype }
        },
        skip_initial_sync: true
      )
    end

    def create_from_coinbase_account(coinbase_account)
      # All Coinbase accounts are crypto exchange accounts
      family = coinbase_account.coinbase_item.family

      # Extract native balance and currency from Coinbase (e.g., USD, EUR, GBP)
      native_balance = coinbase_account.raw_payload&.dig("native_balance", "amount").to_d
      native_currency = coinbase_account.raw_payload&.dig("native_balance", "currency") || family.currency

      attributes = {
        family: family,
        name: coinbase_account.name,
        balance: native_balance,
        cash_balance: 0, # No cash - all value is in holdings
        currency: native_currency,
        accountable_type: "Crypto",
        accountable_attributes: {
          subtype: "exchange",
          tax_treatment: "taxable"
        }
      }

      # Skip initial sync - provider sync will handle balance/holdings creation
      create_and_sync(attributes, skip_initial_sync: true)
    end

    def create_from_binance_account(binance_account)
      account = create_from_crypto_exchange_account(binance_account, family: binance_account.binance_item.family)
      account.set_opening_anchor_balance(balance: 0)
      account
    end

    def create_from_ibkr_account(ibkr_account)
      family = ibkr_account.ibkr_item.family
      default_name = if ibkr_account.ibkr_account_id.present?
        "Interactive Brokers (#{ibkr_account.ibkr_account_id})"
      else
        "Interactive Brokers"
      end

      attributes = {
        family: family,
        name: default_name,
        balance: 0,
        cash_balance: 0,
        currency: ibkr_account.currency.presence || family.currency,
        accountable_type: "Investment",
        accountable_attributes: {
          subtype: "brokerage"
        }
      }

      # Capture the created account in a variable
      create_and_sync(attributes, skip_initial_sync: true)
    end

    def create_from_trading212_account(trading212_account)
      family = trading212_account.trading212_item.family

      attributes = {
        family: family,
        name: trading212_account.name.presence || "Trading 212",
        balance: 0,
        cash_balance: 0,
        currency: trading212_account.currency.presence || family.currency,
        accountable_type: "Investment",
        accountable_attributes: {
          subtype: "brokerage"
        }
      }

      create_and_sync(attributes, skip_initial_sync: true)
    end

    def create_from_trade_republic_account(trade_republic_account)
      family = trade_republic_account.trade_republic_item.family
      is_cash = trade_republic_account.cash?

      attributes = {
        family: family,
        name: trade_republic_account.name.presence || (is_cash ? "Trade Republic Cash" : "Trade Republic Portfolio"),
        balance: 0,
        cash_balance: 0,
        currency: trade_republic_account.currency.presence || family.currency,
        accountable_type: is_cash ? "Depository" : "Investment",
        accountable_attributes: {
          subtype: is_cash ? "checking" : "brokerage"
        }
      }

      create_and_sync(attributes, skip_initial_sync: true)
    end

    def create_from_kraken_account(kraken_account)
      create_from_crypto_exchange_account(kraken_account, family: kraken_account.kraken_item.family)
    end

    # Self-custody assets are wallets, not exchanges: no trade entry by hand,
    # and no cash side. The balance is written by the provider sync, which is
    # the only thing that knows what the chain says.
    def create_from_onchain_wallet_account(onchain_wallet_account)
      family = onchain_wallet_account.onchain_wallet_item.family

      create_and_sync(
        {
          family: family,
          name: onchain_wallet_account.display_name,
          balance: 0,
          cash_balance: 0,
          currency: onchain_wallet_account.currency.presence || family.currency,
          accountable_type: "Crypto",
          accountable_attributes: {
            subtype: "wallet",
            tax_treatment: "taxable"
          }
        },
        skip_initial_sync: true
      )
    end

  
  def purge_manual_logo_on_auto_switch
    # Always purge manual logo when switching from manual to auto source
    # This happens independently of fetch-source availability.
    # Check if logo_source changed from manual to auto by comparing with previous value
    if logo_source_auto? && logo.attached? && logo_source_before_last_save == "manual"
      old_blob = logo.blob
      logo.detach
      old_blob.purge_later
    end
  end

  # Callback condition: should we purge manual logo on auto switch?
  # Must be public because it's used in after_save_commit callback
  def should_purge_manual_logo?
    logo_source_auto? && logo.attached?
  end

  private

  def create_from_crypto_exchange_account(provider_account, family:)
        attributes = {
          family: family,
          name: provider_account.name,
          balance: (provider_account.current_balance || 0).to_d,
          cash_balance: 0,
          currency: provider_account.currency.presence || family.currency,
          accountable_type: "Crypto",
          accountable_attributes: {
            subtype: "exchange",
            tax_treatment: "taxable"
          }
        }

        create_and_sync(attributes, skip_initial_sync: true)
      end

      def build_simplefin_accountable_attributes(simplefin_account, account_type, subtype)
        attributes = {}
        attributes[:subtype] = subtype if subtype.present?

        # Set account-type-specific attributes from SimpleFin data
        case account_type
        when "CreditCard"
          # For credit cards, available_balance often represents available credit
          if simplefin_account.available_balance.present? && simplefin_account.available_balance > 0
            attributes[:available_credit] = simplefin_account.available_balance
          end
        when "Loan"
          # For loans, we might get additional data from the raw_payload
          # This is where loan-specific information could be extracted if available
          # Currently we don't have specific loan fields from SimpleFin protocol
        end

        attributes
      end
  end

  def institution_name
    read_attribute(:institution_name).presence || provider&.institution_name
  end

  def institution_domain
    read_attribute(:institution_domain).presence || provider&.institution_domain
  end

  def manual_crypto_exchange?
    accountable_type == "Crypto" &&
      accountable&.subtype == "exchange" &&
      manual?
  end

  # True when the account has no live sync provider attached. Mirrors the
  # `Account.manual` scope so per-instance checks don't drift from the query.
  def manual?
    account_providers.none? &&
      plaid_account_id.blank? &&
      simplefin_account_id.blank?
  end

  # Default GoalPledge kind for this account. Manual accounts get
  # `manual_save` (resolves on the next valuation), live-synced accounts
  # get `transfer` (resolves when the synced deposit posts). Keeps the
  # decision in one place so the new-pledge controller / preview helper
  # can't disagree on what they're going to save.
  def default_pledge_kind
    # Investment accounts never use manual_save: a positive valuation delta on a
    # brokerage is usually a market move, not a deposit, and would false-match a
    # pledge. They resolve on transfer (cash-inflow) entries only.
    manual? && !investment? ? "manual_save" : "transfer"
  end

  # Total fixed earmark this account currently has reserved across every goal
  # still holding its money (unallocated/whole-balance links reserve no fixed
  # slice). Mirrors Budget#allocated_spending. Scoped to Goal::RELEASED_STATES
  # so this and Goal.pooled_allocations_for never disagree — if they did,
  # free_to_earmark would contradict the figures the goals themselves show.
  def goal_earmarked_total
    GoalAccount.joins(:goal)
               .where(account_id: id)
               .where.not(allocated_amount: nil)
               .where.not(goals: { state: Goal::RELEASED_STATES })
               .sum(:allocated_amount)
               .to_d
  end

  # Headroom left to earmark toward goals before fixed allocations exceed the
  # balance. Negative means the account is over-earmarked. Intended to back a
  # non-blocking over-allocation warning (UI is a follow-up). Mirrors
  # Budget#available_to_allocate.
  def free_to_earmark
    balance.to_d - goal_earmarked_total
  end

  def logo_url
    # Manual source: prioritize the user-uploaded logo.
    #
    # We intentionally do not check whether the blob exists on the backing
    # storage service here. Calling blob.service.exist? would make every
    # logo_url evaluation perform a synchronous remote storage request
    # (S3/R2/GCS), which can significantly slow down account lists and can
    # cause storage outages to break page rendering.
    if logo_source_manual? && logo.attached?
      return Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true)
    end

    # Auto source: if LogoFetcher successfully downloaded and attached a logo,
    # serve that attachment before falling back to remote logo providers.
    if logo_source_auto? && logo.attached?
      return Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true)
    end

    # No usable attachment: fall back to the auto-fetch chain.
    brandfetch = brandfetch_logo_url
    return brandfetch if brandfetch.present?

    return provider.logo_url if provider&.logo_url.present?

    favicon_url
  end


  def favicon_url(domain = institution_domain)
    return nil unless domain.present?

    # Use DuckDuckGo's privacy-friendly favicon service
    "https://icons.duckduckgo.com/ip3/#{domain}.ico"
  end

  def brandfetch_logo_url(domain = institution_domain)
    return nil unless domain.present? && Setting.brand_fetch_client_id.present?

    logo_size = Setting.brand_fetch_logo_size
    "https://cdn.brandfetch.io/#{domain}/icon/fallback/lettermark/w/#{logo_size}/h/#{logo_size}?c=#{Setting.brand_fetch_client_id}"
  end

  def queue_logo_fetch
    # Pass the domain the queue decision was made on so Account::LogoFetcher
    # can discard the fetch if the domain changes while the job is in flight.
    #
    # A domain change also invalidates the previously fetched logo: purge it
    # so a failed replacement fetch falls back to the new domain's Brandfetch
    # or favicon URL instead of serving the old institution's logo
    # indefinitely. Only runs while logo_source is auto, so manual uploads
    # are never touched here.
    #
    # Evaluate effective previous domain, including provider-derived values
    # when persisted attribute was blank
    previous_effective_domain = institution_domain_before_last_save || provider&.institution_domain
    if saved_change_to_institution_domain? && logo.attached? && previous_effective_domain.present?
      old_blob = logo.blob
      logo.detach
      old_blob.purge_later
    end

    # Pass the current institution_domain for domain-based fetches.
    # For provider-only logo fetches, this will be nil but the fetcher handles that.
    FetchLogoJob.perform_later(id, institution_domain)
  end

  # Attach a logo fetched by the background job without marking it as a
  # manual upload. Attaching on an unchanged record saves the parent record,
  # so without this opt-out the save would reclassify the fetched logo as a
  # manual upload (see set_logo_source).
  def attach_fetched_logo(*attachables)
    @attaching_fetched_logo = true
    logo.attach(*attachables)
  ensure
    @attaching_fetched_logo = false
  end

  # Callback condition: should we queue logo fetch?
  # Must be public because it's used in after_save_commit callback
  def should_queue_logo_fetch?
    return false unless logo_source_auto?

    # Only queue if there's actually a source to fetch from
    has_domain = institution_domain.present?
    has_provider_logo = provider&.logo_url.present?
    return false unless has_domain || has_provider_logo
    # Queue on relevant changes or if no logo attached yet
    saved_change_to_institution_domain? ||
      saved_change_to_logo_source? ||
      !logo.attached?
  end

  private

    def mark_manual_if_logo_uploaded
      write_attribute(:logo_source, "manual")
    end



    # True when this save carries an attachment that is not yet persisted for
    # the account. A params upload defers its blob to the save (pending blob
    # id nil or different from the persisted row), while a fetcher attach on
    # an unchanged record persists immediately, making the pending and
    # persisted blob ids equal — so an unrelated later save stays neutral.
    def logo_upload_in_this_save?
      persisted_blob_id =
        ActiveStorage::Attachment.where(record_id: id, record_type: self.class.name, name: "logo").pick(:blob_id)
      return true if persisted_blob_id.nil?

      logo.blob&.id != persisted_blob_id
    end

    # Server-side guard for logo uploads: the form's accept="image/*" is only
    # a picker hint, so content type and size are enforced here too.
    def validate_logo_file
      blob = logo.blob

      if blob.content_type.present? && ACCEPTED_LOGO_CONTENT_TYPES.exclude?(blob.content_type)
        errors.add(:logo, :invalid_type)
      end

      if blob.byte_size > MAX_LOGO_BYTES
        errors.add(:logo, :too_large, max_megabytes: MAX_LOGO_BYTES / 1.megabyte)
      end
    end

    def clean_institution_domain
      return unless read_attribute(:institution_domain).present?

      value = read_attribute(:institution_domain).strip
      value = "//#{value}" unless value.match?(/\Ahttps?:\/\//i)

      domain = URI.parse(value).host&.downcase&.sub(/\Awww\./, "")

      self.institution_domain = domain if domain.present?
    rescue URI::InvalidURIError
      # Preserve the original value when it cannot be parsed as a URI.
    end

  public

  def destroy_later
    transaction do
      mark_for_deletion!
      DestroyJob.perform_later(self)
    end
  end

  # Override destroy to handle error recovery for accounts
  def destroy
    super
  rescue => e
    # If destruction fails, transition back to disabled state
    # This provides a cleaner recovery path than the generic scheduled_for_deletion flag
    disable! if may_disable?
    raise e
  end

  def current_holdings
    if (provider_snapshot_date = latest_provider_holdings_snapshot_date)
      holdings
        .where.not(account_provider_id: nil)
        .where(date: provider_snapshot_date)
        .where.not(qty: 0)
        .order(amount: :desc)
    else
      holdings
        .where(currency: currency)
        .where.not(qty: 0)
        .where(
          id: holdings.select("DISTINCT ON (security_id) id")
                      .where(currency: currency)
                      .order(:security_id, date: :desc)
        )
        .order(amount: :desc)
    end
  end

  def latest_provider_holdings_snapshot_date
    holdings.where.not(account_provider_id: nil).maximum(:date)
  end

  def start_date
    first_entry_date = entries.minimum(:date) || Date.current
    first_entry_date - 1.day
  end

  def lock_saved_attributes!
    super
    accountable.lock_saved_attributes!
  end

  def first_valuation
    entries.valuations.order(:date).first
  end

  def first_valuation_amount
    first_valuation&.amount_money || balance_money
  end

  # Get short version of the subtype label
  def short_subtype_label
    accountable_class.short_subtype_label_for(subtype) || accountable_class.display_name
  end

  # Get long version of the subtype label
  def long_subtype_label
    accountable_class.long_subtype_label_for(subtype) || accountable_class.display_name
  end

  def supports_default?
    depository? || credit_card?
  end

  def eligible_for_transaction_default?
    supports_default? && active? && !linked?
  end

  # Determines if this account supports manual trade entry
  # Investment accounts always support trades; Crypto only if subtype is "exchange"
  def supports_trades?
    return true if investment?
    return accountable.supports_trades? if crypto? && accountable.respond_to?(:supports_trades?)
    false
  end

  def traded_standard_securities
    Security.where(id: holdings.select(:security_id))
            .standard
            .distinct
            .order(:ticker)
  end

  # The balance type determines which "component" of balance is being tracked.
  # This is primarily used for balance related calculations and updates.
  #
  # "Cash" = "Liquid"
  # "Non-cash" = "Illiquid"
  # "Investment" = A mix of both, including brokerage cash (liquid) and holdings (illiquid)
  def balance_type
    case accountable_type
    when "Depository", "CreditCard"
      :cash
    when "Property", "Vehicle", "OtherAsset", "Loan", "OtherLiability"
      :non_cash
    when "Investment", "Crypto"
      :investment
    else
      raise "Unknown account type: #{accountable_type}"
    end
  end

  def owned_by?(user)
    user.present? && owner_id == user.id
  end

  def shared_with?(user)
    return false if user.nil?

    owned_by?(user) ||
      if account_shares.loaded?
        account_shares.any? { |s| s.user_id == user.id }
      else
        account_shares.exists?(user: user)
      end
  end

  def shared?
    account_shares.any?
  end

  def permission_for(user)
    return :owner if owned_by?(user)
    account_shares.find_by(user: user)&.permission&.to_sym
  end

  def share_with!(user, permission: "read_only", include_in_finances: true)
    account_shares.create!(user: user, permission: permission, include_in_finances: include_in_finances)
  end

  def unshare_with!(user)
    account_shares.where(user: user).destroy_all
  end

  def auto_share_with_family!
    # Guests get read_only, everyone else read_write. This mirrors
    # Family#auto_share_existing_accounts_with so a guest's permission on an
    # account is the same whether they joined before or after it was created.
    records = family.users.where.not(id: owner_id).pluck(:id, :role).map do |user_id, role|
      { account_id: id, user_id: user_id,
        permission: role == "guest" ? "read_only" : "read_write",
        include_in_finances: true, created_at: Time.current, updated_at: Time.current }
    end

    AccountShare.insert_all(records, unique_by: %i[account_id user_id]) if records.any?
  end

  private

    def assign_default_owner
      return if owner.present?

      if Current.user.present? && Current.user.family_id == family_id
        self.owner = Current.user
      else
        self.owner =
          family&.users&.where(role: "admin")&.order(:created_at)&.first ||
          family&.users&.where(role: "super_admin")&.order(:created_at)&.first ||
          family&.users&.order(:created_at)&.first
      end
    end

    def owner_belongs_to_family
      owner_user = User.lock.find_by(id: owner_id)
      return if owner_user&.family_id == family_id

      errors.add(:owner, :invalid, message: "must belong to the same family as the account")
    end

    def capture_account_statement_ids_to_move
      @statement_ids_to_move = account_statements.ids
    end

    def move_account_statements_to_inbox
      statement_ids = Array(@statement_ids_to_move).compact
      return if statement_ids.empty?

      # Bypass callbacks deliberately: the account was destroyed, so linked statements need a direct inbox move.
      AccountStatement.where(id: statement_ids).update_all(
        account_id: nil,
        review_status: "unmatched",
        match_confidence: nil,
        updated_at: Time.current
      )
    end

    def cleanup_transfers
      transaction_ids = entries.where(entryable_type: "Transaction").pluck(:entryable_id)

      transfers = Transfer.where(inflow_transaction_id: transaction_ids).or(Transfer.where(outflow_transaction_id: transaction_ids))
                         .includes(inflow_transaction: { entry: { account: :family } }, outflow_transaction: { entry: { account: :family } })

      transfers.find_each(&:destroy!)
    end
end
