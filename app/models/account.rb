class Account < ApplicationRecord
  include AASM, Syncable, Monetizable, Chartable, Linkable, Enrichable, Anchorable, Reconcileable, TaxTreatable

  validates :name, :balance, :currency, presence: true

  belongs_to :family
  belongs_to :import, optional: true

  has_many :import_mappings, as: :mappable, dependent: :destroy, class_name: "Import::Mapping"
  has_many :entries, dependent: :destroy
  has_many :transactions, through: :entries, source: :entryable, source_type: "Transaction"
  has_many :valuations, through: :entries, source: :entryable, source_type: "Valuation"
  has_many :trades, through: :entries, source: :entryable, source_type: "Trade"
  has_many :holdings, dependent: :destroy
  has_many :balances, dependent: :destroy

  monetize :balance, :cash_balance

  enum :classification, { asset: "asset", liability: "liability" }, validate: { allow_nil: true }

  scope :visible, -> { where(status: [ "draft", "active" ]) }
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

  has_one_attached :logo, dependent: :purge_later

  delegated_type :accountable, types: Accountable::TYPES, dependent: :destroy
  delegate :subtype, to: :accountable, allow_nil: true

  # Writer for subtype that delegates to the accountable
  # This allows forms to set subtype directly on the account
  def subtype=(value)
    accountable&.subtype = value
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

    def create_and_sync(attributes, skip_initial_sync: false)
      attributes[:accountable_attributes] ||= {} # Ensure accountable is created, even if empty
      # Default cash_balance to balance unless explicitly provided (e.g., Crypto sets it to 0)
      attrs = attributes.dup
      attrs[:cash_balance] = attrs[:balance] unless attrs.key?(:cash_balance)
      account = new(attrs)
      initial_balance = attributes.dig(:accountable_attributes, :initial_balance)&.to_d

      transaction do
        account.save!

        manager = Account::OpeningBalanceManager.new(account)
        result = manager.set_opening_balance(balance: initial_balance || account.balance)
        raise result.error if result.error
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

      attributes = {
        family: simplefin_account.simplefin_item.family,
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

      attributes = {
        family: enable_banking_account.enable_banking_item.family,
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


    private

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

  def logo_url
    provider&.logo_url
  end

  def destroy_later
    mark_for_deletion!
    DestroyJob.perform_later(self)
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

  # Determines if this account supports manual trade entry
  # Investment accounts always support trades; Crypto only if subtype is "exchange"
  def supports_trades?
    return true if investment?
    return accountable.supports_trades? if crypto? && accountable.respond_to?(:supports_trades?)
    false
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
end
