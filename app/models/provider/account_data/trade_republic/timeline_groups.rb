require "base64"
require "digest"
require "json"
require "set"

# One connection timeline, two ordered topics, with each provider response
# retained before it can contribute to the sealed account fanout. Continuation
# carries a digest; its raw inputs live only in the encrypted generation pages.
module Provider::AccountData::TradeRepublic::TimelineGroups
  DETAILS_PER_GROUP = 32
  MAX_TIMELINE_EVENTS = 5_000
  MAX_CAPTURE_BYTES = 8 * 1024 * 1024
  TIMELINE_KEY = "trade_republic_timeline"

  def fetch_activity_group(start_cursor:, generation_id:, cursor: start_cursor, captured_groups:, accounts:)
    unless captured_groups.is_a?(Array) && captured_groups.size <= Ingestion::TransactionGroupAssembler::MAX_PAGES && accounts.is_a?(Hash)
      raise ArgumentError
    end
    context = timeline_context(accounts)
    captures = validate_timeline_prefix(captured_groups, generation_id, start_cursor, context)
    expected_cursor = captured_groups.last&.next_cursor || start_cursor
    raise ArgumentError unless cursor == expected_cursor
    state = captures.last&.fetch("next_state") || { "phase" => "page", "topic" => 0, "after" => nil, "pages" => 0 }
    raise ArgumentError unless %w[page details].include?(state.fetch("phase"))
    topic = Provider::TradeRepublicClient::IngestionClient::TOPICS.fetch(state.fetch("topic"))
    pages = {}
    if state.fetch("phase") == "page"
      if state.fetch("pages") >= Provider::TradeRepublicClient::MAX_TIMELINE_PAGES
        raise Provider::AccountData::IncompletePage, "Trade Republic topic exceeds its captured page budget"
      end
      response = normalized_object(client.get_timeline_page(topic: topic, cursor: state["after"]))
      ensure_timeline_capture_bound!(response)
      rows = validate_timeline_response(response, accounts)
      prior = captures.select { |value| value.fetch("kind") == "page" }
      if prior.sum { |value| value.fetch("response").fetch("response").fetch("items").size } + rows.size > MAX_TIMELINE_EVENTS
        raise Provider::AccountData::IncompletePage, "Trade Republic timeline exceeds its retained event budget"
      end
      validate_duplicate_routes!(prior, rows)
      seen = prior.flat_map { |value| value.fetch("response").fetch("response").fetch("items").map { |row| row.fetch("id").to_s } }.to_set
      selected = rows.select { |row| seen.add?(normalized_id(row.fetch(:id))) }
      details = selected.select { |row| Provider::TradeRepublicClient::DETAIL_CATEGORIES.include?(category_for(row)) }.map { |row| normalized_id(row.fetch(:id)) }
      capture = { "kind" => "page", "topic" => topic, "request_cursor" => state["after"], "response" => response,
        "selected_ids" => selected.map { |row| normalized_id(row.fetch(:id)) }, "detail_ids" => details }
      check_timeline_cursor!(capture, prior)
      if details.any?
        next_state = state.merge("phase" => "details", "page_index" => captures.size, "offset" => 0)
      else
        pages = timeline_account_pages(capture, {}, accounts)
        next_state = after_timeline_page(state, response)
      end
    else
      source = captures.fetch(state.fetch("page_index"))
      raise ArgumentError unless source.fetch("kind") == "page" && source.fetch("topic") == topic
      offset = state.fetch("offset")
      ids = source.fetch("detail_ids")
      raise ArgumentError unless offset.is_a?(Integer) && offset >= 0 && offset < ids.size
      selected = ids.slice(offset, DETAILS_PER_GROUP)
      details = selected.each_with_object({}) do |id, result|
        response = normalized_object(client.get_event_detail(event_id: id))
        owner = normalized_object(source.fetch("response").fetch("account"))
        current_owner = normalized_object(response.fetch(:account))
        unless normalized_id(current_owner.fetch(:securitiesAccountNumber)) == normalized_id(owner.fetch(:securitiesAccountNumber)) &&
            current_owner[:currency] == owner[:currency]
          raise ArgumentError
        end
        result[id] = response.fetch(:response)
        ensure_timeline_capture_bound!(result)
      end
      capture = { "kind" => "details", "topic" => topic, "page_index" => state.fetch("page_index"), "offset" => offset, "details" => details }
      if offset + selected.size < ids.size
        next_state = state.merge("offset" => offset + selected.size)
      else
        all_details = captures.select { |value| value["kind"] == "details" && value["page_index"] == state.fetch("page_index") }
          .each_with_object({}) { |value, result| result.merge!(value.fetch("details")) }.merge(details)
        raise ArgumentError unless all_details.keys.sort == ids.sort
        pages = timeline_account_pages(source, all_details, accounts)
        next_state = after_timeline_page(state, source.fetch("response"))
      end
    end
    capture = capture.merge("version" => 1, "context" => context, "state" => state, "next_state" => next_state)
    complete = next_state.fetch("phase") == "complete"
    Provider::AccountData::TransactionGroup.new(resource: "activities", folding_policy: "first_observation",
      generation_id: generation_id, start_cursor: start_cursor, request_cursor: cursor,
      next_cursor: timeline_cursor(generation_id, captures + [ capture ]), complete: complete,
      account_pages: pages, unassigned_removed_ids: [], evidence: { TIMELINE_KEY => capture })
  rescue ArgumentError, KeyError, TypeError, NoMethodError, IndexError
    raise Provider::AccountData::InvalidResponse, "Invalid Trade Republic timeline continuation", cause: nil
  end

  private
    def ensure_timeline_capture_bound!(value)
      payload = Ingestion::Codec.dump(Provider::AccountData::Page.new(records: [], complete: false, evidence: { "capture" => value }))
      if JSON.generate(payload).bytesize > MAX_CAPTURE_BYTES
        raise Provider::AccountData::IncompletePage, "Trade Republic response group exceeds its byte budget"
      end
    end

    def timeline_context(accounts)
      unless accounts.values.all? { |binding| binding.is_a?(Hash) && binding["resource"] == "activities" }
        raise ArgumentError
      end
      linked_cash = accounts.select { |id, binding| cash_account?(external_id: id) && binding["account_id"].present? }.keys.sort
      raise ArgumentError unless linked_cash == @linked_cash_ids.sort
      { "observed_at" => @observed_at.utc.iso8601(9), "timezone" => @timezone, "currency" => @currency,
        "linked_cash_ids" => linked_cash, "labels" => @labels, "accounts" => accounts, "topology" => @topology }
    end

    def validate_timeline_prefix(groups, generation_id, start_cursor, context)
      previous = nil
      captures = []
      groups.each do |group|
        value = group.evidence.fetch(TIMELINE_KEY)
        unless group.resource == "activities" && group.folding_policy == "first_observation" && !group.complete? &&
            group.generation_id == generation_id && group.start_cursor == start_cursor &&
            group.request_cursor == (previous ? previous.next_cursor : start_cursor) &&
            value["version"] == 1 && value["context"] == context &&
            value["state"] == (captures.last&.fetch("next_state") || { "phase" => "page", "topic" => 0, "after" => nil, "pages" => 0 })
          raise ArgumentError
        end
        captures << value
        raise ArgumentError unless group.next_cursor == timeline_cursor(generation_id, captures)
        previous = group
      end
      captures
    end

    def timeline_cursor(generation_id, captures)
      # No upstream cursor, account data or detail content is embedded in the
      # checkpoint. The digest binds the entire original ordered capture prefix.
      payload = Ingestion::Codec.dump(Provider::AccountData::Page.new(records: [], complete: false, evidence: { "captures" => captures }))
      "tr-timeline-v1:" + Base64.urlsafe_encode64(JSON.generate("generation_id" => generation_id,
        "sha256" => Digest::SHA256.hexdigest(JSON.generate(payload))), padding: false)
    end

    def validate_timeline_response(response, accounts)
      owner = normalized_object(response.fetch(:account))
      id = normalized_id(owner.fetch(:securitiesAccountNumber))
      records = %w[portfolio cash].map { |kind| normalize_account(owner, kind: kind) }
      raise ArgumentError unless accounts.keys.sort == records.map { |record| record[:external_id] }.sort
      records.each do |record|
        binding = accounts.fetch(record[:external_id])
        raise ArgumentError if binding["account_currency"] && binding["account_currency"] != record[:currency]
      end
      rows = checked_rows(normalized_object(response.fetch(:response)).fetch(:items))
      rows.each { |row| normalized_id(row.fetch(:id)) }
      after = response[:next_cursor]
      raise ArgumentError unless after.nil? || (after.is_a?(String) && after.present? && after.bytesize <= 16_384 && rows.any?)
      rows
    end

    def check_timeline_cursor!(capture, prior)
      after = capture.fetch("response")["next_cursor"]
      return unless after
      seen = prior.select { |value| value.fetch("topic") == capture.fetch("topic") }.map { |value| value["request_cursor"] }
      if (seen + [ capture["request_cursor"] ]).include?(after)
        raise Provider::AccountData::IncompletePage, "Trade Republic timeline repeats an upstream cursor"
      end
    end

    def validate_duplicate_routes!(prior, rows)
      routes = {}
      existing = prior.flat_map { |value| value.fetch("response").fetch("response").fetch("items") }
      (existing + rows).each do |raw|
        row = normalized_object(raw)
        id = normalized_id(row.fetch(:id))
        category = category_for(row)
        route = if category == "orderExecution"
          "portfolio"
        elsif CASH_CATEGORIES.key?(category)
          @linked_cash_ids.any? ? "cash" : "portfolio"
        end
        if route && routes[id] && routes[id] != route
          raise Provider::AccountData::InvalidResponse, "Trade Republic event identity has conflicting account routes"
        end
        routes[id] ||= route
      end
    end

    def after_timeline_page(state, response)
      after = response["next_cursor"]
      if after
        { "phase" => "page", "topic" => state.fetch("topic"), "after" => after, "pages" => state.fetch("pages") + 1 }
      elsif state.fetch("topic").zero?
        { "phase" => "page", "topic" => 1, "after" => nil, "pages" => 0 }
      else
        { "phase" => "complete", "topic" => 1, "after" => nil, "pages" => state.fetch("pages") + 1 }
      end
    end

    def timeline_account_pages(source, details, accounts)
      response = source.fetch("response").deep_dup
      selected = source.fetch("selected_ids").to_set
      response.fetch("response")["items"] = response.fetch("response").fetch("items").select { |row| selected.include?(row.fetch("id").to_s) }
      # A repeated ID within one topic page has the same first-observation policy
      # as a duplicate on a later page/topic. Never compare financial attributes.
      response.fetch("response")["items"] = response.fetch("response").fetch("items").uniq { |row| row.fetch("id").to_s }
      capture = Provider::AccountData::Page.new(records: [], complete: false, evidence: {
        "topic" => source.fetch("topic"), "request_cursor" => source["request_cursor"], "response" => response, "details" => details })
      %w[portfolio cash].to_h do |kind|
        account = normalize_account(response.fetch("account"), kind: kind)
        page = normalize_timeline_page(capture: capture, account: account)
        [ account[:external_id], page ]
      end
    end
end
