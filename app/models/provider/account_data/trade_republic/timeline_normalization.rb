module Provider::AccountData::TradeRepublic::TimelineNormalization
  TRANSFER_TYPES = %w[PAYMENT_INBOUND PAYMENT_OUTBOUND INCOMING_TRANSFER OUTGOING_TRANSFER INCOMING_TRANSFER_DELEGATION OUTGOING_TRANSFER_DELEGATION].freeze
  CASH_CATEGORIES = {
    "PAYMENT_RECEIVED" => [ "contribution", -1 ],
    "POC_CREATED" => [ "withdrawal", 1 ],
    "INTEREST_PAYOUT_CREATED" => [ "interest", -1 ],
    "DIVIDEND" => [ "dividend", -1 ]
  }.freeze
  CASH_LABELS = {
    "CARD_TRANSACTION" => "card_payment", "card_successful_transaction" => "card_payment", "CARD_CASH_BACK" => "card_payment",
    "CARD_ATM_WITHDRAWAL" => "cash_withdrawal", "CARD_ORDER_FEE" => "card_fee", "card_refund" => "card_refund",
    "CARD_REFUND" => "card_refund", "TAX_REFUND" => "tax_refund", "SSP_TAX_CORRECTION" => "tax_refund", "ssp_tax_correction_invoice" => "tax_refund"
  }.freeze

  # One provider-wide topic page plus bounded detail responses. This is captured
  # evidence, not an independently committable per-account activity stream.
  def capture_timeline_page(topic:, cursor: nil)
    response = normalized_object(client.get_timeline_page(topic: topic, cursor: cursor))
    rows = checked_rows(normalized_object(response.fetch(:response)).fetch(:items))
    supported = rows.select { |row| Provider::TradeRepublicClient::DETAIL_CATEGORIES.include?(category_for(row)) }
    if supported.size > Provider::TradeRepublicClient::MAX_TIMELINE_DETAILS
      raise Provider::AccountData::IncompletePage, "Trade Republic timeline exceeds its detail capture budget"
    end
    details = supported.map { |row| normalized_id(row.fetch(:id)) }.uniq.to_h do |id|
      detail = normalized_object(client.get_event_detail(event_id: id))
      owner, detail_owner = normalized_object(response.fetch(:account)), normalized_object(detail.fetch(:account))
      unless normalized_id(owner.fetch(:securitiesAccountNumber)) == normalized_id(detail_owner.fetch(:securitiesAccountNumber)) &&
          owner[:currency] == detail_owner[:currency]
        raise ArgumentError
      end
      [ id, detail.fetch(:response) ]
    end
    Provider::AccountData::Page.new(records: [], complete: false, mode: "delta",
      evidence: { "topic" => topic, "request_cursor" => cursor, "response" => response, "details" => details })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Trade Republic timeline capture", cause: nil
  end

  def normalize_timeline_page(capture:, account:)
    raise ArgumentError unless capture.is_a?(Provider::AccountData::Page) && capture.records.empty? && !capture.complete?
    evidence = normalized_object(capture.evidence)
    raise ArgumentError unless Provider::TradeRepublicClient::IngestionClient::TOPICS.include?(evidence[:topic])
    response = normalized_object(evidence.fetch(:response))
    check_owner!(response.fetch(:account), account)
    details = normalized_object(evidence.fetch(:details))
    rows = checked_rows(normalized_object(response.fetch(:response)).fetch(:items))
    skipped = 0
    records = rows.filter_map do |item|
      id = normalized_id(item.fetch(:id))
      category = category_for(item)
      if Provider::TradeRepublicClient::DETAIL_CATEGORIES.include?(category) && !details.key?(id)
        raise Provider::AccountData::IncompletePage, "Trade Republic timeline detail has not been captured"
      end
      event = bridge_event(item, details[id])
      record = normalize_activity(event, account: account)
      skipped += 1 if record.nil?
      record
    end
    if records.group_by { |record| record[:external_id] }.any? { |_id, values| values.map(&:attributes).uniq.size > 1 }
      raise ArgumentError
    end
    Provider::AccountData::Page.new(records: records.uniq { |record| record[:external_id] }, complete: false, mode: "delta",
      coverage: { "absence_authoritative" => false }, warnings: skipped.positive? ? [ { "code" => "unmapped_or_partitioned_events", "count" => skipped } ] : [],
      evidence: { "capture" => evidence, "linked_cash_ids" => @linked_cash_ids, "labels" => @labels })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Trade Republic timeline page", cause: nil
  end

  # Accepts the documented bridge shape retained in historical encrypted caches.
  # This method is pure: security resolution and financial writes happen later.
  def normalize_activity(raw, account:)
    event = normalized_object(raw)
    id = normalized_id(event.fetch(:id))
    category = event[:category].to_s
    detail = normalized_object(event[:detail] || {})
    signed = detail[:signed_amount] || detail[:amount]
    if event[:eventType] == "CARD_CASH_BACK" && !signed.nil? && decimal(signed).negative?
      category = "POC_CREATED"
    end
    return nil if cash_account?(account) && category == "orderExecution"
    return nil if !cash_account?(account) && linked_cash_for?(account) && category != "orderExecution"
    return nil unless category == "orderExecution" || CASH_CATEGORIES.key?(category)
    %i[amount signed_amount quantity price fees taxes].each { |key| decimal(detail[key]) unless detail[key].nil? }
    date = date_in_zone(event.fetch(:timestamp))
    currency = normalized_currency(detail[:currency].presence || account[:currency])
    external_id = "trade_republic_event_#{id}"
    if category == "orderExecution"
      isin = detail[:isin].presence
      return nil if isin.nil? || detail[:quantity].nil?
      isin = normalized_id(isin)
      quantity = decimal(detail[:quantity])
      return nil if quantity.zero?
      price = detail[:price].nil? ? nil : decimal(detail[:price])
      price = nil if price&.zero?
      amount = detail[:amount].nil? ? nil : decimal(detail[:amount])
      amount = quantity.abs * price.abs if (amount.nil? || amount.zero?) && price
      return nil if amount.nil? || amount.zero?
      price ||= amount.abs / quantity.abs
      buy = quantity.positive?
      action = @labels.fetch(buy ? "buy" : "sell")
      Ingestion::Record.activity(external_id: external_id, date: date, name: "#{action} #{quantity.abs} shares of #{isin}",
        currency: currency, amount: buy ? -amount.abs : amount.abs, quantity: quantity, price: price,
        activity_type: buy ? "buy" : "sell", ledger_type: "trade", security: security_descriptor(isin, detail[:name].presence || event[:title]),
        metadata: { investment_activity_label: buy ? "Buy" : "Sell", extra: { trade_republic: {
          event_id: event[:id], event_type: event[:eventType], isin: isin, fees: detail[:fees], taxes: detail[:taxes], provider_name: detail[:name]
        }.compact } })
    else
      return nil if detail[:amount].nil?
      amount = decimal(detail[:amount])
      return nil if amount.zero?
      type, sign = CASH_CATEGORIES.fetch(category)
      label_key = %w[PAYMENT_RECEIVED POC_CREATED].include?(category) ? CASH_LABELS.fetch(event[:eventType], type) : type
      label = @labels.fetch(label_key)
      Ingestion::Record.activity(external_id: external_id, date: date, name: event[:title].presence || label,
        currency: currency, amount: sign * amount.abs, activity_type: type, ledger_type: "transaction",
        metadata: { investment_activity_label: label, notes: event[:subtitle].presence,
          kind: TRANSFER_TYPES.include?(event[:eventType]) ? "funds_movement" : nil,
          extra: { trade_republic: { event_id: detail[:event_id] || external_id, category: detail[:category],
            event_type: event[:eventType], title: event[:title], subtitle: event[:subtitle],
            provider_detail: detail.except(:amount, :signed_amount, :currency) }.compact } })
    end
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid Trade Republic activity", cause: nil
  end

  def normalize_legacy_activity(raw, account:)
    event = normalized_object(raw).deep_dup
    if event[:detail].is_a?(Hash)
      %i[amount signed_amount quantity price fees taxes].each do |key|
        event[:detail][key] = legacy_decimal(event[:detail][key]) if event[:detail].key?(key)
      end
    end
    normalize_activity(event, account: account)
  end

  private
    def category_for(item)
      item[:category].presence || Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES[item[:eventType].to_s]
    end

    def bridge_event(item, raw_detail)
      fallback = normalized_object(item[:amount] || {})
      # Validation precedes metadata capture; native numerical Float input never
      # acquires legitimacy by first being converted to a string.
      decimal(fallback[:value]) unless fallback[:value].nil?
      detail = { amount: fallback[:value], signed_amount: fallback[:value], currency: fallback[:currency] }.compact
      detail.merge!(normalize_detail(raw_detail, item: item)) unless raw_detail.nil?
      item.slice(:id, :timestamp, :title, :subtitle, :eventType).merge(category: category_for(item), detail: detail)
    end

    def normalize_detail(raw, item:)
      rows, strings = detail_nodes(raw)
      shares = find_detail_row(rows, [ "aktien", "anteile", "shares", "aktien hinzugefügt", "shares added", "aktien erhalten", "shares received", "aktien entfernt", "shares removed", "aktien gesendet", "shares sent" ])
      total = find_detail_row(rows, %w[gesamt total])
      fees = find_detail_row(rows, Provider::TradeRepublicClient::FEE_TITLES)
      taxes = find_detail_row(rows, Provider::TradeRepublicClient::TAX_TITLES)
      quantity = decimal_from_row(shares)
      if quantity.nil?
        match = strings.filter_map { |value| value.match(/\A\s*([\d.,]+)\s*[×x]/) }.first
        quantity = localized_decimal(match[1]) if match
      end
      title = shares&.dig(:title).to_s.downcase
      if quantity && (title.match?(/entfernt|removed|gesendet|sent/) || item[:subtitle].to_s.downcase.include?("sell"))
        quantity = -quantity.abs
      end
      amount = decimal_from_row(total)
      return {} if quantity.nil? && amount.nil?
      item_strings = detail_nodes(item).last
      isin = (item_strings + strings).find { |value| value.match?(/\A[A-Z]{2}[A-Z0-9]{9}\d\z/) }
      asset = find_detail_row(rows, %w[wertpapier asset vermögenswert security])
      { isin: isin, name: item[:title].presence || detail_text(asset), quantity: quantity&.to_s, amount: amount&.abs&.to_s,
        currency: total&.dig(:detail, :value, :currency) || shares&.dig(:detail, :value, :currency),
        fees: decimal_from_row(fees)&.to_s, taxes: decimal_from_row(taxes)&.to_s }.compact
    end

    def detail_nodes(raw)
      rows, strings, stack = [], [], [ raw ]
      nodes = 0
      until stack.empty?
        value = stack.pop
        nodes += 1
        raise ArgumentError if nodes > 20_000
        case value
        when Hash
          value = normalized_object(value)
          rows.concat(checked_rows(value[:data])) if value.key?(:title) && value[:data].is_a?(Array)
          stack.concat(value.values.reverse)
        when Array then stack.concat(value.reverse)
        when String then strings << value
        end
      end
      [ rows, strings ]
    end

    def find_detail_row(rows, titles)
      rows.find { |row| titles.include?(row[:title].to_s.downcase.strip) }
    end

    def detail_text(row)
      row&.dig(:detail, :text) || row&.dig(:detail, :value, :text)
    end

    def decimal_from_row(row)
      text = detail_text(row)
      return nil if text.blank?
      localized_decimal(text.to_s.gsub(/[^\d,.-]/, ""))
    end

    def localized_decimal(value)
      # German decimal comma and English decimal point are explicitly supported.
      # Reject ambiguous/malformed punctuation instead of silently producing zero.
      if value.include?(",")
        if value.count(",") == 1 && (!value.include?(".") || value.rindex(",") > value.rindex("."))
          value = value.delete(".").tr(",", ".")
        elsif value.match?(/\A-?\d{1,3}(?:,\d{3})+(?:\.\d+)?\z/)
          value = value.delete(",")
        else
          raise ArgumentError
        end
      end
      decimal(value)
    end
end
