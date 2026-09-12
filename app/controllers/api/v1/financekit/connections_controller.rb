class Api::V1::Financekit::ConnectionsController < Api::V1::Financekit::BaseController
  def capabilities
    available = Financekit.enabled?(current_resource_owner.family)
    render_json({ available: available, protocol_versions: [ Financekit::VERSION ],
      delivery: "foreground_sync", max_payload_bytes: Financekit::MAX_BYTES, max_records: Financekit::MAX_RECORDS,
      max_accounts: Financekit::MAX_ACCOUNTS, transaction_statuses: Financekit::Payload::STATUSES,
      amount_precision: 19, amount_scale: 4 })
  end

  def create
    item = Financekit::Enrollment.create!(current_resource_owner, input)
    render_json(connection_data(item), status: :created)
  end

  def show
    sources = connection.financekit_accounts.order(:id)
    total = sources.count
    render_json(connection_data(connection).merge(
      accounts: sources.includes(:account).offset((safe_page_param - 1) * safe_per_page_param).limit(safe_per_page_param).map { |source| mapping_data(source) },
      pagination: { page: safe_page_param, per_page: safe_per_page_param, total_count: total,
        total_pages: (total.to_f / safe_per_page_param).ceil }))
  end

  def mapping
    source = FinancekitAccount.map!(connection, params[:source_id], input)
    render_json(mapping_data(source))
  end

  def destroy
    connection.disconnect!
    head :no_content
  end

  private

    def connection_data(item)
      { id: item.id, status: item.status, last_device_contact_at: item.last_device_contact_at,
        last_imported_at: item.last_imported_at, last_captured_at: item.last_captured_at }
    end

    def mapping_data(source)
      source.as_json(only: %i[source_id mapping_version name currency accountable_type subtype ledger_timezone])
        .merge("account_id" => source.account&.id)
    end
end
