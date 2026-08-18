class OpenBankingIoAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  # open-banking.io passes through the bank's ISO 20022 ExternalCashAccountType1Code
  # (Enable Banking's cashAccountType, falling back to its account type).
  #
  # Only codes with an unambiguous Sure equivalent are mapped. Anything else -- OTHR,
  # SACC (settlement), TAXE, TRAS, CHAR, COMM, CPAC, NREX, ODFT -- deliberately falls
  # through to nil so the setup screen asks the user rather than guessing wrong.
  #
  # Note most EU banks report CACC for every personal account, savings included: the ten
  # Danish accounts this was built against are all CACC. So "Checking" showing up
  # everywhere is the bank's classification, not a mapping failure.
  OPEN_BANKING_IO_ACCOUNT_TYPE_MAP = {
    # Current / transaction accounts
    "CACC" => { accountable_type: "Depository", subtype: "checking" },   # Current
    "TRAN" => { accountable_type: "Depository", subtype: "checking" },   # Transacting
    "SLRY" => { accountable_type: "Depository", subtype: "checking" },   # Salary
    "CASH" => { accountable_type: "Depository", subtype: "checking" },   # Cash payment
    # Savings-shaped
    "SVGS" => { accountable_type: "Depository", subtype: "savings" },    # Savings
    "LLSV" => { accountable_type: "Depository", subtype: "savings" },    # Limited liquidity savings
    "ONDP" => { accountable_type: "Depository", subtype: "savings" },    # Overnight deposit
    "MOMA" => { accountable_type: "Depository", subtype: "money_market" }, # Money market
    # Credit
    "CARD" => { accountable_type: "CreditCard", subtype: "credit_card" },
    # Debt
    "LOAN" => { accountable_type: "Loan", subtype: nil },
    "MGLD" => { accountable_type: "Loan", subtype: nil }                 # Marginal lending
  }.freeze

  # ISO 20022 booked balance code preferred as the account's current balance.
  BOOKED_BALANCE_TYPE = "ITBD".freeze
  # ISO 20022 closing booked balance code, the secondary booked preference.
  CLOSING_BOOKED_BALANCE_TYPE = "CLBD".freeze
  # Booked-balance preference order for current_balance. Both are genuine booked
  # balances (interim booked, then closing booked); an available balance is never
  # used here. When none is present we leave current_balance untouched rather than
  # picking an arbitrary balance.
  BOOKED_BALANCE_PREFERENCE = [ BOOKED_BALANCE_TYPE, CLOSING_BOOKED_BALANCE_TYPE ].freeze
  # ISO 20022 available balance code.
  AVAILABLE_BALANCE_TYPE = "ITAV".freeze

  # open-banking.io covers the EU/EEA and UK, so a bank that reports no currency is far
  # likelier to be euro-denominated than anything else. Single source for the fallback.
  DEFAULT_CURRENCY = "EUR".freeze

  # Accountable types whose balance Sure stores as a positive magnitude (money owed).
  DEBT_ACCOUNT_TYPES = %w[CreditCard Loan].freeze

  # Encryptable#encryption_ready? asks ActiveRecordEncryptionConfig.explicitly_configured?,
  # which is true only for env vars or credentials. But config/initializers/active_record_encryption.rb
  # AUTO-DERIVES fully working keys from SECRET_KEY_BASE for self-hosted installs -- so in
  # the most common deployment encryption is live at runtime while explicitly_configured?
  # is false, and these columns would be declared unencrypted.
  #
  # That is survivable for an access token. It is not for a PKCS#8 ECDH private key: it is
  # the one secret that decrypts every zero-knowledge envelope this provider ever fetches,
  # and it would sit in plaintext in the table, in every backup and every replica.
  #
  # ready? adds runtime_configured?, which is the predicate that matches what is actually
  # in force. Overridden here rather than in Encryptable because ~30 models share that
  # concern and flipping it globally is a data migration -- whereas these tables are new,
  # so getting it right costs nothing today and would cost a migration later.
  def self.encryption_ready?
    ActiveRecordEncryptionConfig.ready?
  end

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :open_banking_io_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: :open_banking_io_item_id, allow_nil: true }

  def current_account
    account
  end

  def suggested_account_type
    OPEN_BANKING_IO_ACCOUNT_TYPE_MAP[account_type.to_s.upcase]&.fetch(:accountable_type)
  end

  def suggested_subtype
    OPEN_BANKING_IO_ACCOUNT_TYPE_MAP[account_type.to_s.upcase]&.[](:subtype)
  end

  # The balance Sure should store for this provider account as `accountable_type`.
  #
  # Debt accounts are stored as a positive magnitude, and an account with only an
  # available (ITAV) balance falls back to it rather than seeding a bogus zero. Shared by
  # the account-creation path and OpenBankingIoAccount::Processor so the rule lives once.
  def normalized_balance_for(accountable_type)
    balance = current_balance || available_balance || 0
    accountable_type.to_s.in?(DEBT_ACCOUNT_TYPES) ? balance.abs : balance
  end

  # Investment accounts track holdings separately, so their cash balance starts at zero.
  def cash_balance_for(accountable_type)
    accountable_type.to_s == "Investment" ? 0 : normalized_balance_for(accountable_type)
  end

  def subtype_for(accountable_type)
    return "credit_card" if accountable_type.to_s == "CreditCard"
    return nil unless suggested_account_type == accountable_type.to_s

    suggested_subtype
  end

  # Creates the Sure Account this provider account will be linked to.
  def build_linked_account!(family:, accountable_type:)
    subtype = subtype_for(accountable_type)

    Account.create_and_sync(
      {
        family: family,
        name: name,
        balance: normalized_balance_for(accountable_type),
        cash_balance: cash_balance_for(accountable_type),
        currency: currency || DEFAULT_CURRENCY,
        accountable_type: accountable_type,
        accountable_attributes: subtype.present? ? { subtype: subtype } : {}
      },
      skip_initial_sync: true
    )
  end

  def upsert_open_banking_io_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access
    balances = snapshot[:balances].is_a?(Array) ? snapshot[:balances] : []

    booked = find_booked_balance(balances)
    available = find_balance(balances, AVAILABLE_BALANCE_TYPE)
    booked_amount = parse_balance_amount(booked)

    display_name = snapshot[:display_name].presence ||
                   snapshot[:account_name].presence ||
                   snapshot[:aspsp_name].presence ||
                   I18n.t("open_banking_io_account.fallback")

    assign_attributes(
      available_balance: parse_balance_amount(available),
      currency: parse_currency(snapshot[:currency]) || parse_currency(booked&.dig(:currency)) || DEFAULT_CURRENCY,
      name: display_name,
      account_id: snapshot[:id].presence,
      formatted_account: snapshot[:iban].presence || snapshot[:bban].presence,
      account_status: snapshot[:needs_reconnect] ? "requires_update" : "good",
      account_type: snapshot[:account_type],
      provider: "open_banking_io",
      institution_metadata: {
        id: snapshot[:aspsp_name],
        name: snapshot[:aspsp_name],
        country: snapshot[:aspsp_country],
        bic: snapshot[:bic],
        account_number: snapshot[:iban].presence || snapshot[:bban].presence,
        holder: snapshot[:owner_name]
      }.compact,
      raw_payload: account_snapshot
    )

    # Only update the current (booked) balance when the feed actually carries a
    # booked balance. Never fall back to an available balance or an arbitrary
    # first entry — that silently corrupts the account balance.
    self.current_balance = booked_amount unless booked_amount.nil?

    save!
  end

  def upsert_open_banking_io_transactions_snapshot!(transactions_snapshot)
    assign_attributes(raw_transactions_payload: transactions_snapshot)
    save!
  end

  private

    def find_balance(balances, type)
      balances.find { |b| b.is_a?(Hash) && b.with_indifferent_access[:type].to_s.upcase == type }&.with_indifferent_access
    end

    def find_booked_balance(balances)
      BOOKED_BALANCE_PREFERENCE.each do |type|
        found = find_balance(balances, type)
        return found if found
      end
      nil
    end

    def parse_balance_amount(balance)
      return nil unless balance.is_a?(Hash)

      value = balance.with_indifferent_access[:amount]
      return nil if value.nil? || value == ""

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for open-banking.io account #{id}, defaulting to EUR")
    end
end
