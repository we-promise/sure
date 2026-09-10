class Api::V1::Financekit::ConnectionsController < Api::V1::Financekit::BaseController
  def capabilities
    available = Financekit.enabled?(current_resource_owner.family)
    render_json({ available: available, protocol_versions: [ Financekit::VERSION ], envelope_versions: [ 1 ],
      delivery: "device_push", max_envelope_bytes: Financekit::MAX_BYTES, max_records: Financekit::MAX_RECORDS,
      max_accounts: Financekit::MAX_ACCOUNTS, max_queued_batches: Financekit::MAX_QUEUED,
      transaction_statuses: Financekit::Payload::STATUSES, amount_precision: 19, amount_scale: 4,
      jwe_alg: "RSA-OAEP", jwe_enc: "A256GCM", jws_alg: "ES256",
      keys: available ? Financekit::Crypto.keys : nil })
  end

  def create
    item = Financekit::Enrollment.create!(current_resource_owner, input)
    render_json(connection_data(item).merge(keys: Financekit::Crypto.keys), status: :created)
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

  def device_replacement
    connection.replace_device!(input)
    render_json(connection_data(connection).merge(keys: Financekit::Crypto.keys))
  end

  def receipt
    generation = Integer(params.require(:generation), exception: false)
    raise Financekit::Error.new("invalid_generation", 400) unless generation&.positive?
    batch = connection.financekit_batches.find_by!(batch_id: params[:batch_id], generation: generation)
    render_json({ receipt: Financekit::Crypto.receipt(batch) })
  end

  def destroy
    connection.disconnect!
    head :no_content
  end

  private

    def connection_data(item)
      { id: item.id, generation: item.generation, status: item.status, next_sequence: item.next_sequence,
        previous_digest: item.previous_digest, last_device_contact_at: item.last_device_contact_at,
        last_accepted_at: item.last_accepted_at, last_imported_at: item.last_imported_at,
        last_captured_at: item.last_captured_at,
        device_key_thumbprint: JWT::JWK::Thumbprint.new(JWT::JWK.import(item.device_public_key)).generate }
    end

    def mapping_data(source)
      source.as_json(only: %i[source_id mapping_version name currency accountable_type subtype ledger_timezone])
        .merge("account_id" => source.account&.id)
    end
end
