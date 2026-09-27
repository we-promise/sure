module Account::Linkable
  extend ActiveSupport::Concern

  included do
    # New generic provider association
    has_many :account_providers, dependent: :destroy

    # Legacy provider associations - kept for backward compatibility during migration
    belongs_to :plaid_account, optional: true
    belongs_to :simplefin_account, optional: true

    # SQL-level mirror of `linked?`. Use this for set-based checks (e.g. bulk
    # `EXISTS`) so both definitions stay in sync. If `linked?` adds a new
    # provider source, update this scope too.
    scope :linked, -> {
      left_outer_joins(:account_providers)
        .where(
          "account_providers.id IS NOT NULL OR accounts.plaid_account_id IS NOT NULL OR accounts.simplefin_account_id IS NOT NULL"
        )
        .distinct
    }
  end

  # A "linked" account gets transaction and balance data from a third party like Plaid or SimpleFin
  def linked?
    account_providers.any? || plaid_account.present? || simplefin_account.present?
  end

  # An "offline" or "unlinked" account is one where the user tracks values and
  # adds transactions manually, without the help of a data provider
  def unlinked?
    !linked?
  end
  alias_method :manual?, :unlinked?

  # Returns the primary provider adapter for this account
  # If multiple providers exist, returns the first one
  def provider
    return nil unless linked?

    account_providers.first&.adapter
  end

  # Returns all provider adapters for this account
  def providers
    if accounting_start_date
      AccountProvider.where(account_id: id).includes(:provider).map(&:adapter).compact
    else
      @providers ||= account_providers.map(&:adapter).compact
    end
  end

  # Returns the provider adapter for a specific provider type
  def provider_for(provider_type)
    account_provider = account_providers.find_by(provider_type: provider_type)
    account_provider&.adapter
  end

  # Returns the raw provider account record (e.g. EnableBankingAccount) for a specific provider type
  def provider_account_for(provider_type)
    account_providers.find_by(provider_type: provider_type)&.provider
  end

  # Convenience method to get the provider name
  def provider_name
    # Try new system first
    return provider&.provider_name if provider.present?

    # Fall back to legacy system
    return "plaid" if plaid_account.present?
    return "simplefin" if simplefin_account.present?

    nil
  end

  # Check if account is linked to a specific provider
  def linked_to?(provider_type)
    account_providers.exists?(provider_type: provider_type)
  end

  # Whether this account's provider applies the category matcher to imported
  # transactions, and therefore honors `enable_category_matcher`. Add a provider
  # here only once its entry processor checks the toggle; listing one that
  # ignores it shows the user a switch that does nothing.
  CATEGORY_MATCHER_PROVIDER_TYPES = %w[PlaidAccount UpAccount MonobankAccount].freeze

  def supports_category_matcher?
    return true if plaid_account.present?

    account_providers.exists?(provider_type: CATEGORY_MATCHER_PROVIDER_TYPES)
  end

  # Check if holdings can be deleted
  # If account has multiple providers, returns true only if ALL providers allow deletion
  # This prevents deleting holdings that would be recreated on next sync
  def can_delete_holdings?
    return true if unlinked?

    providers.all?(&:can_delete_holdings?)
  end

  # Deleting any dated row removes its journal, so protect the whole managed
  # security while retaining deletion rights for unrelated manual positions.
  def can_delete_holding?(holding)
    return false if provider_managed_security?(holding.security_id)

    providers.reject(&:position_only?).all?(&:can_delete_holdings?)
  end

  # A position publisher owns selected securities rather than the account total.
  def position_tracking?
    providers.any?(&:position_only?)
  end

  # Cash and other securities remain editable when every link publishes positions.
  def manual_accounting?
    return plaid_account_id.nil? && simplefin_account_id.nil? && providers.all?(&:position_only?) if accounting_start_date

    unlinked? || (plaid_account_id.nil? && simplefin_account_id.nil? && providers.all?(&:position_only?))
  end

  # Scope quantity ownership to a security and, for dated edits, its connection.
  def provider_managed_security?(security_id, date: nil)
    providers.any? do |adapter|
      adapter.position_only? && adapter.managed_security_ids.include?(security_id) &&
        (date.nil? || adapter.position_start_date.nil? || date >= adapter.position_start_date)
    end
  end

  # Cash anchors require forward accounting even after the publisher disconnects.
  def balance_calculation_strategy
    manual_accounting? || position_tracking? || accounting_start_date ? :forward : :reverse
  end

  # Preserve existing dated snapshots before moving their publishers to a ledger.
  def reconcile_position_journals!
    ids = providers.select(&:position_only?).flat_map(&:managed_security_ids).uniq
    holdings.where(security_id: ids, date: ..Date.current)
      .select("DISTINCT ON (security_id) holdings.*").order(:security_id, date: :desc)
      .each(&:reconcile_trade_quantity!)
  end
end
