class QuestradeActivitiesFetchJob < ApplicationJob
  include QuestradeAccount::DataHelpers
  queue_as :default

  Request = QuestradeAccount::ActivitiesRequest
  Session = QuestradeItem::CredentialSession

  # Correctness lives in the durable request revision; queue uniqueness must not
  # suppress a replacement request merely because its source account is the same.
  def self.enqueue_for(source, start_date:, sync: nil)
    Request.enqueue(source, start_date: start_date, sync: sync)
  end

  # Retain old keywords only to explicitly refuse old deliveries. A worker never
  # reconstructs original authority or date bounds from today's source or args.
  def perform(source, request_id: nil, revision: nil, **legacy_arguments)
    Request.refuse!("Legacy activity job needs an explicit disposition") if legacy_arguments.any?
    Request.with_claim(source, request_id: request_id, revision: revision) do |session, request|
      begin
        rows = fetch(session, request)
        if rows.empty? && request.document.fetch("retry_count") < Request::MAX_RETRIES
          ticket = request.defer!(source)
          session.after_release { Request.dispatch(ticket) }
          next
        end
        if rows.any?
          source.reload
          snapshot_context = QuestradeItem::LegacyAccess.capture_context(source)
          merged = merge_activities(source.raw_activities_payload || [], rows)
          source.upsert_activities_snapshot!(merged, mark_synced: false, expected_context: snapshot_context,
            publication_verifier: request.method(:verify!))
          QuestradeAccount::ActivitiesProcessor.new(source.reload, publication_verifier: request.method(:verify!), raise_on_error: true).process
        end
        completed = request.complete!(source)
        session.after_release { Request.broadcast_completed(completed) }
      rescue *Session::DENIAL_ERRORS
        raise
      rescue Provider::Questrade::Error => error
        if !error.is_a?(Provider::Questrade::AuthenticationError) &&
            %i[network_error rate_limited server_error].include?(error.error_type) && request.document.fetch("retry_count") < Request::MAX_RETRIES
          ticket = request.defer!(source)
          session.after_release { Request.dispatch(ticket) }
          next
        end
        session.require_update! if error.is_a?(Provider::Questrade::AuthenticationError)
        request.fail!(source)
        raise
      rescue StandardError => error
        request.fail!(source)
        raise
      end
    end
  end

  private
    def fetch(session, request)
      value = request.document
      response = session.provider.get_activities(account_id: value.fetch("context").fetch("remote_id"),
        start_date: Date.iso8601(value.fetch("start_date")), end_date: Date.iso8601(value.fetch("end_date")))
      unless response.is_a?(Hash) && response[:activities].is_a?(Array) && response[:activities].all? { |row| row.is_a?(Hash) }
        raise Provider::Questrade::Error.new("Invalid Questrade activities response", :invalid_response)
      end
      response.fetch(:activities)
    rescue *Session::DENIAL_ERRORS, Provider::Questrade::AuthenticationError
      raise
    rescue Provider::Questrade::Error => error
      # Preserve failure as failure. The caller can defer a classified transient
      # request, but never complete it as an empty response.
      DebugLogEntry.capture(category: "provider_sync_error", level: "error", message: "Questrade activity request failed",
        source: self.class.name, provider_key: "questrade", family: session.item.family,
        metadata: { request_id: request.document.fetch("id"), error_class: error.class.name })
      raise
    end

    def merge_activities(existing, incoming)
      existing = existing.with_indifferent_access.fetch(:activities) if existing.is_a?(Hash)
      Request.refuse!("Questrade cached activities are malformed") unless existing.is_a?(Array) && existing.all? { |row| row.is_a?(Hash) }
      by_id = {}
      (existing + incoming).each do |row|
        data = sdk_object_to_hash(row).with_indifferent_access
        key = [ data[:transactionDate], data[:action], data[:symbolId], data[:netAmount], data[:description], data[:currency], data[:type] ].join("-")
        by_id[key] = data
      end
      by_id.values
    end
end
