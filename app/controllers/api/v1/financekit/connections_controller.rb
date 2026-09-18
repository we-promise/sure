class Api::V1::Financekit::ConnectionsController < Api::V1::Financekit::BaseController
  def capabilities
    available = Financekit.enabled?(current_resource_owner.family)
    render_json({ available: available, protocol_versions: [ Financekit::VERSION ],
      delivery: "background_publisher", max_payload_bytes: Financekit::MAX_BYTES,
      max_records: Financekit::MAX_RECORDS, max_accounts: Financekit::MAX_ACCOUNTS,
      max_queued_batches: Financekit::MAX_QUEUED, transaction_statuses: Financekit::Payload::STATUSES,
      amount_precision: 19, amount_scale: 4 })
  end

  def create
    result = Financekit::Enrollment.create!(current_resource_owner, input)
    render_json(connection_data(result.item), status: result.created ? :created : :ok)
  end

  def show
    mappings = connection.financekit_accounts.order(:id)
    total = mappings.count
    render_json(connection_data(connection).merge(
      accounts: mappings.includes(financekit_account_lineage: :account)
        .offset((safe_page_param - 1) * safe_per_page_param).limit(safe_per_page_param).map { |mapping| mapping_data(mapping) },
      pagination: { page: safe_page_param, per_page: safe_per_page_param, total_count: total,
        total_pages: (total.to_f / safe_per_page_param).ceil }))
  end

  def mapping
    mapping = FinancekitAccount.map!(connection, params[:source_id], input)
    render_json(mapping_data(mapping))
  end

  def activate
    credential = connection.activate!
    render_json(publisher_configuration(connection, credential))
  end

  def credential
    credential = connection.renew_credential!
    render_json(publisher_configuration(connection, credential))
  end

  def repair
    credential = connection.repair!
    render_json(publisher_configuration(connection, credential))
  end

  def destroy
    connection.disconnect!
    head :no_content
  end

  private

    def connection_data(item)
      { id: item.id, connection_id: item.id, publisher_id: item.publisher_id, status: item.status,
        generation: item.generation, stream_id: item.stream_id, next_sequence: item.next_sequence,
        repair_reason: item.repair_reason, last_device_contact_at: item.last_device_contact_at,
        last_accepted_at: item.last_accepted_at, last_imported_at: item.last_imported_at,
        last_downstream_at: item.last_downstream_at, last_captured_at: item.last_captured_at,
        open_conflicts: item.financekit_conflicts.open.count }
    end

    def mapping_data(mapping)
      mapping.as_json(only: %i[source_id mapping_version name institution_name currency accountable_type subtype ledger_timezone])
        .merge("lineage_id" => mapping.financekit_account_lineage_id, "account_id" => mapping.account&.id)
    end

    def publisher_configuration(item, credential)
      connection_data(item).merge(
        protocol_version: Financekit::VERSION,
        server_url: request.base_url,
        upload_url: api_v1_financekit_publisher_batches_url(publisher_id: item.publisher_id),
        consent: item.consent.except("recorded_at"),
        account_bindings: item.selected_accounts.order(:source_id).map do |mapping|
          { source_account_id: mapping.source_id, lineage_id: mapping.financekit_account_lineage_id,
            mapping_version: mapping.mapping_version }
        end,
        max_records_per_batch: Financekit::MAX_RECORDS,
        max_bytes_per_batch: Financekit::MAX_BYTES,
        publisher_credential: credential)
    end
end
