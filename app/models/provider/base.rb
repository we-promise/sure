# Base class for all provider adapters
# Provides common interface for working with different third-party data providers
#
# To create a new provider adapter:
# 1. Inherit from Provider::Base
# 2. Implement #provider_name
# 3. Include optional modules (Provider::Syncable, Provider::InstitutionMetadata)
# 4. Register with Provider::Factory in the class body
#
# Example:
#   class Provider::AcmeAdapter < Provider::Base
#     Provider::Factory.register("AcmeAccount", self)
#     include Provider::Syncable
#     include Provider::InstitutionMetadata
#
#     def provider_name
#       "acme"
#     end
#   end
class Provider::Base
  attr_reader :provider_account, :account

  def initialize(provider_account, account: nil)
    @provider_account = provider_account
    @account = account || provider_account.account
  end

  # Provider identification - must be implemented by subclasses
  # @return [String] The provider name (e.g., "plaid", "simplefin")
  def provider_name
    raise NotImplementedError, "#{self.class} must implement #provider_name"
  end

  # Defines which account types this provider supports
  # Override in subclasses to specify supported account types
  # @return [Array<String>] Array of account type class names (e.g., ["Depository", "CreditCard"])
  def self.supported_account_types
    []
  end

  # How each list loads a provider's items unless its declaration says otherwise:
  # the Bank sync page only needs to know which connections exist, and a panel
  # reads them whole.
  ITEM_LISTS = {
    settings_page: ->(items) { items.ordered.select(:id) },
    settings_panel: ->(items) { items.ordered }
  }.freeze

  def self.item_list_query(query)
    return query if query.respond_to?(:call)

    ->(items) { query.reduce(items) { |relation, scope| relation.public_send(scope) } }
  end
  private_class_method :item_list_query

  # Declares the family connection (the provider's `*_items` record) this adapter
  # serves. Lists that cover every account provider, such as
  # ProviderConnectionStatus::PROVIDERS, are derived from these declarations.
  # @param key [String] The provider key, matching #provider_name (e.g., "brex")
  # @param name [String] The display name, used as the panel title and in
  #   Provider::Metadata
  # @param item_class [String] The connection model; defaults to "<Key>Item"
  # @param accounts [Symbol] The connection's provider account association
  # @param linked_accounts [Symbol, nil] An extra association to preload for status
  # @param panel [true, Hash, nil] The provider's settings panel; a Hash may set
  #   turbo_id: (defaults to key) and auto_open:. The partial is "<key>_panel".
  # @param metadata [Hash, nil] Provider::Metadata attributes (region:, kinds:,
  #   maturity:, logo_text:, logo_color:, domain:, ...)
  # @param lists [Hash] How a list loads the family's items, overriding ITEM_LISTS:
  #   scope names applied in order, or a lambda over the family's item relation.
  def self.declares_connection(key:, name:, item_class: "#{key.camelize}Item", accounts: :"#{key}_accounts",
                               linked_accounts: nil, panel: nil, metadata: nil, lists: {})
    unknown_lists = lists.keys - ITEM_LISTS.keys
    raise ArgumentError, "#{key}: unknown lists #{unknown_lists.join(', ')}" if unknown_lists.any?

    @connection_declaration = {
      key: key,
      type: item_class,
      association: item_class.underscore.pluralize.to_sym,
      accounts: accounts,
      linked_accounts: linked_accounts,
      lists: ITEM_LISTS.merge(lists.transform_values { |query| item_list_query(query) }).freeze
    }.compact.freeze
    panel_options = panel.is_a?(Hash) ? panel : {}
    @panel_declaration = panel && {
      key: key,
      title: name,
      turbo_id: panel_options.fetch(:turbo_id, key),
      partial: "#{key}_panel",
      auto_open: panel_options[:auto_open]
    }.compact.freeze
    if metadata&.key?(:name) || metadata&.key?(:key)
      raise ArgumentError, "#{key}: declare key: and name: once, outside metadata:"
    end
    @metadata_declaration = metadata && metadata.merge(key: key, name: name).freeze
  end

  def self.connection_declaration
    @connection_declaration
  end

  def self.panel_declaration
    @panel_declaration
  end

  def self.metadata_declaration
    @metadata_declaration
  end

  # Returns provider connection configurations
  # Override in subclasses to provide connection metadata for UI
  # @param family [Family] The family to check connection availability for
  # @return [Array<Hash>] Array of connection configurations with keys:
  #   - key: Unique identifier (e.g., "lunchflow", "plaid_us")
  #   - name: Display name (e.g., "Lunch Flow", "Plaid")
  #   - description: User-facing description
  #   - can_connect: Boolean, whether family can connect to this provider
  #   - new_account_path: Proc that generates path for new account flow
  #   - existing_account_path: Proc that generates path for linking existing account
  #   - member_connectable: Boolean, whether a non-admin member may connect it
  def self.connection_configs(family:)
    []
  end

  # The provider item class that represents a connection for this adapter, if
  # the provider has one. Used to read the item's declared credential scope.
  # @return [Class, nil]
  def self.connection_item_class
    nil
  end

  # May a non-admin household member create one of these connections? False
  # unless the item class has declared `credential_scope :per_connection`, so
  # an unclassified provider stays admin-only.
  # @return [Boolean]
  def self.member_connectable?
    klass = connection_item_class
    klass.respond_to?(:member_connectable?) && klass.member_connectable?
  end

  # Returns the provider type (class name)
  # @return [String] The provider account class name
  def provider_type
    provider_account.class.name
  end

  # Whether this provider allows deletion of holdings
  # Override in subclass if provider supports holdings deletion
  # @return [Boolean] True if holdings can be deleted, false otherwise
  def can_delete_holdings?
    false
  end

  # Provider-specific raw data payload
  # @return [Hash, nil] The raw payload from the provider
  def raw_payload
    provider_account.raw_payload
  end

  # Returns metadata about this provider and account
  # Automatically includes institution metadata if the adapter includes Provider::InstitutionMetadata
  # @return [Hash] Metadata hash
  def metadata
    base_metadata = {
      provider_name: provider_name,
      provider_type: provider_type
    }

    # Include institution metadata if the module is included
    if respond_to?(:institution_metadata)
      base_metadata.merge!(institution: institution_metadata)
    end

    base_metadata
  end
end
