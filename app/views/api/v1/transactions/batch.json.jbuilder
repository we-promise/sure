# frozen_string_literal: true

json.results @batch_response[:results] do |result|
  json.index result[:index]
  json.client_ref result[:client_ref] if result[:client_ref].present?
  json.status result[:status]

  if result[:transaction].present?
    json.transaction do
      json.partial! "transaction", transaction: result[:transaction]
    end
  end

  json.error result[:error] if result[:error].present?
  json.errors result[:errors] if result[:errors].present?
end

json.summary @batch_response[:summary]
