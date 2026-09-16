require "base64"
require "digest/sha2"

class Provider::AccountData::Plaid < Provider::AccountData::Adapter
  include Provider::AccountData::Normalization
  include InvestmentNormalization

  class PaginationRestartRequired < Provider::AccountData::PaginationRestartRequired
  end

  DEFINITION = Provider::AccountData::Definition.new(
    key: "plaid", source: "plaid", credential_scope: "connection", capabilities: %w[transactions holdings activities],
    fields: [ { name: "access_token", type: "text", secret: true } ]
  )

  def self.definition
    DEFINITION
  end

  def self.context_sources
    %i[connection_details application_credentials plaid_deployment_binding]
  end

  def self.frozen_context_sources
    %i[plaid_deployment_binding]
  end

  def self.runtime_options
    [ :include_pending ]
  end

  def self.build(credentials:, settings:, context:)
    values = credentials.with_indifferent_access
    application = context.fetch(:application_credentials).with_indifferent_access
    region, environment = context.fetch(:region), context.fetch(:environment)
    unless %w[us eu].include?(region) && application[:region] == region && application[:environment] == environment &&
        ::Plaid::Configuration::Environment.key?(environment) && %i[client_id secret].all? { |key| application[key].is_a?(String) && application[key].present? }
      raise ArgumentError, "Plaid application credentials must match the connection region and environment"
    end
    DeploymentBinding.verify_factory!(snapshot: context.fetch(:plaid_deployment_binding), credentials: credentials, settings: settings, context: context)
    config = ::Plaid::Configuration.new
    config.server_index = ::Plaid::Configuration::Environment.fetch(environment)
    config.api_key["PLAID-CLIENT-ID"] = application.fetch(:client_id)
    config.api_key["PLAID-SECRET"] = application.fetch(:secret)
    config.debugging = false
    client = Provider::Plaid::IngestionClient.new(api_client: ::Plaid::ApiClient.new(config), access_token: values.fetch(:access_token), region: region)
    pending = context[:pending_override] ? context.fetch(:configured_options).fetch(:include_pending) : context.fetch(:pending_preference)
    new(client: client, timezone: context.fetch(:timezone), observed_at: context.fetch(:observed_at), region: region,
      item_id: context.fetch(:connection_details).with_indifferent_access.fetch(:external_id), include_pending: pending,
      history_days: settings.with_indifferent_access[:investment_history_days] || 730)
  end

  def initialize(client:, timezone:, observed_at:, region:, item_id:, include_pending: true, history_days: 730)
    super(client: client)
    raise ArgumentError unless %w[us eu].include?(region) && [ true, false ].include?(include_pending) && history_days.is_a?(Integer) && history_days.between?(1, 730)
    @timezone, @observed_at, @region, @item_id = timezone, observed_at.to_time, region, normalized_id(item_id)
    @include_pending, @history_days = include_pending, history_days
  end

  def capabilities
    @region == "eu" ? [ "transactions" ] : super
  end

  def list_accounts(cursor: nil)
    raise ArgumentError unless cursor.nil?
    item_response = client.get_item
    item = normalized_object(normalized_object(item_response).fetch(:item))
    raise ArgumentError unless item[:item_id] == @item_id
    products = (checked_strings(item.fetch(:available_products)) + checked_strings(item.fetch(:billed_products))).uniq
    response = client.get_accounts
    check_item!(response)
    institution_response = item[:institution_id] ? client.get_institution(institution_id: item[:institution_id]) : nil
    institution = institution_response && normalized_object(institution_response).fetch(:institution)
    rows = checked_rows(normalized_object(response).fetch(:accounts))
    records = rows.map { |raw| normalize_account(raw, products: products, institution: institution) }
    raise ArgumentError unless records.map { |record| record[:external_id] }.uniq.size == records.size
    Provider::AccountData::Page.new(records: records, complete: true, mode: "snapshot",
      evidence: { "item" => item_response, "accounts" => response, "institution" => institution_response })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Plaid account inventory", cause: nil
  end

  def normalize_account(raw, products: [], institution: nil)
    data = normalized_object(raw)
    balances = normalized_object(data.fetch(:balances))
    current = balances[:current].nil? ? nil : decimal(balances[:current])
    available = balances[:available].nil? ? nil : decimal(balances[:available])
    raise ArgumentError if current.nil? && available.nil?
    details = institution ? normalized_object(institution).slice(:name, :url, :primary_color, :institution_id).to_h : {}
    type = normalized_id(data[:type])
    currency = normalized_currency(balances[:iso_currency_code])
    metadata = { account_subtype: data[:subtype], products: products, institution: details,
      account_enrichment: { name: data[:name], subtype: mapped_subtype(type, data[:subtype]), accountable_type: mapped_type(type) },
      balance_policy: { debt_transform: "preserve", debt_types: [], current_anchor: true } }
    # Investment cash needs holdings and the security catalog before it can be
    # observed; inventory balances alone do not establish a cash breakdown.
    metadata[:balance_provided] = false if type == "investment"
    Ingestion::Record.account(external_id: normalized_id(data[:account_id]), name: data[:name], currency: currency, account_type: type,
      balance: current || available, available_balance: available, cash_balance: type == "investment" ? nil : current || available,
      sensitive_details: { mask: data[:mask] }, metadata: metadata)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Plaid account", cause: nil
  end

  def normalize_legacy_account(raw, **options)
    data = normalized_object(raw).deep_dup
    %i[current available limit].each { |key| data[:balances][key] = legacy_decimal(data[:balances][key]) if data[:balances].key?(key) }
    normalize_account(data, **options)
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    raise Provider::AccountData::UnsupportedCapability, "Plaid requires staged item-wide transaction generations"
  end

  def transaction_scope
    :connection
  end

  def fetch_transaction_group(start_cursor:, generation_id:, cursor: start_cursor)
    response = client.get_transactions_page(cursor: cursor)
    data = normalized_object(response)
    modified, added, removed = %i[modified added removed].map { |key| checked_rows(data.fetch(key)) }
    complete = data.fetch(:has_more) == false
    raise ArgumentError unless [ true, false ].include?(data[:has_more])
    changes = modified.map { |raw| [ raw, "modified" ] } + added.map { |raw| [ raw, "added" ] }
    grouped = changes.group_by { |raw, _type| normalized_id(raw[:account_id]) }
    removals, unassigned = {}, []
    removed.each do |raw|
      id = normalized_id(raw[:transaction_id])
      if raw[:account_id].present?
        (removals[normalized_id(raw[:account_id])] ||= []) << id
      else
        unassigned << id
      end
    end
    pages = (grouped.keys + removals.keys).uniq.to_h do |id|
      rows = grouped.fetch(id, [])
      selected = @include_pending ? rows : rows.reject { |raw, _type| raw[:pending] == true }
      records = selected.map do |raw, type|
        record = normalize_transaction(raw)
        Ingestion::Record.transaction(**record.attributes.merge(metadata: record[:metadata].merge(change_type: type)))
      end
      page = Provider::AccountData::Page.new(records: records, complete: false, mode: "delta",
        removed_ids: removals.fetch(id, []).uniq, coverage: { "removal_policy" => "exact_external_id", "pending_absence_authoritative" => false },
        warnings: selected.size < rows.size ? [ { "code" => "pending_transactions_excluded", "count" => rows.size - selected.size } ] : [])
      [ id, page ]
    end
    Provider::AccountData::TransactionGroup.new(generation_id: generation_id, start_cursor: start_cursor, request_cursor: cursor,
      folding_policy: "modified_added_removed",
      next_cursor: data.fetch(:next_cursor), complete: complete, account_pages: pages, unassigned_removed_ids: unassigned.uniq,
      evidence: { "response" => response })
  rescue Provider::Plaid::IngestionClient::Error => error
    if cursor != start_cursor || error.error_code == "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION"
      raise PaginationRestartRequired.new(generation_id: generation_id, start_cursor: start_cursor), cause: nil
    end
    raise
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Plaid transaction group", cause: nil
  end

  def normalize_transaction(raw, account: nil)
    data = normalized_object(raw)
    check_account!(data, account) if account
    pending = data[:pending]
    raise ArgumentError unless [ true, false ].include?(pending)
    merchant = if data[:merchant_name].present?
      { external_id: data[:merchant_entity_id], name: data[:merchant_name], website_url: data[:website], logo_url: data[:logo_url] }.compact
    end
    Ingestion::Record.transaction(external_id: normalized_id(data[:transaction_id]), name: data[:merchant_name] || data[:original_description],
      amount: decimal(data[:amount]), currency: normalized_currency(data[:iso_currency_code]), date: date_in_zone(data[:date]), pending: pending,
      pending_external_id: data[:pending_transaction_id], metadata: { merchant: merchant, category_bootstrap: "empty_family",
        category_candidates: category_candidates(data.dig(:personal_finance_category, :detailed)),
        extra: { plaid: { pending: pending, pending_transaction_id: data[:pending_transaction_id] } } })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Plaid transaction", cause: nil
  end

  def normalize_legacy_transaction(raw, account: nil)
    data = normalized_object(raw).deep_dup
    data[:amount] = legacy_decimal(data[:amount])
    normalize_transaction(data, account: account)
  end

  private
    def checked_rows(value)
      raise ArgumentError unless value.is_a?(Array) && value.size <= Provider::Plaid::IngestionClient::MAX_ROWS && value.all? { |row| row.is_a?(Hash) }
      value.map(&:with_indifferent_access)
    end

    def checked_strings(value)
      raise ArgumentError unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) }
      value
    end

    def check_item!(response)
      item = normalized_object(response)[:item]
      raise ArgumentError unless item.is_a?(Hash) && item[:item_id] == @item_id
    end

    def check_account!(data, account)
      raise ArgumentError unless data[:account_id] == account[:external_id]
    end

    def products_for(account)
      checked_strings((account[:metadata] || {}).with_indifferent_access.fetch(:products, []))
    end

    def category_candidates(value)
      return nil unless value.is_a?(String)
      PlaidAccount::Transactions::CategoryTaxonomy::CATEGORIES_MAP.each_value do |parent|
        child = parent[:detailed_categories][value.downcase.to_sym]
        next unless child
        return { exact_names: [ value.downcase ], aliases: child[:aliases], fallback_aliases: parent[:aliases], normalization: "legacy_ascii" }
      end
      nil
    end

    def mapped_type(type)
      { "depository" => "Depository", "credit" => "CreditCard", "loan" => "Loan", "investment" => "Investment", "other" => "OtherAsset" }.fetch(type)
    end

    def mapped_subtype(type, subtype)
      # The established table contains only static strings/classes; no legacy
      # processor or account model is instantiated by this pure mapping.
      PlaidAccount::TypeMappable::TYPE_MAPPING.fetch(type.to_sym).fetch(:subtype_mapping)[subtype] || "other"
    end

    def legacy_decimal(value)
      return value unless value.is_a?(Float)
      raise ArgumentError unless value.finite?
      BigDecimal(value.to_s)
    end
end
