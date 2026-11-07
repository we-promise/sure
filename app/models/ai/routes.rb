# THE routing table (section 5.1): each AI feature's lane, what its models need, its consent
# level and the data it sends. Changing any of these changes what data leaves the box, so it
# goes through review and the architecture tests and can't be changed at runtime.
#
# Feature keys are permanent once released: they appear in config files, `llm_usages.operation`,
# consent records, Langfuse trace names and i18n keys. Every `sends:` key and every consent key
# has a description in config/locales/models/ai/en.yml (test/architecture/ai_routing_matrix_test).
module Ai::Routes
  MATRIX = {
    chat:              { lane: :interactive, needs: %i[tools streaming],        consent: :user,
                         sends: %i[chat_messages looked_up_financial_data stored_document_text] },
    bill_setup:        { lane: :interactive, needs: %i[structured_output],      consent: :user,
                         sends: %i[transaction_dates transaction_amounts transaction_names category_names bill_configuration] },
    # A route entry reads (a model with structured output; vision or documents per way of reading)
    # or transcribes (an OCR model, read before the text model extracts), section 8.1.
    extract_pdf:       { lane: :prompt,      needs: { generation: %i[structured_output], ocr: %i[ocr] }, consent: :user,
                         sends: %i[uploaded_document] },
    embed:             { lane: :prompt,      needs: %i[embedding],              consent: :user,
                         sends: %i[depends_on_vector_store] },
    search_documents:  { lane: :interactive, route_of: :embed, consent_as: :embed, consent: :user,
                         sends: %i[search_query] },
    categorize:        { lane: :background,  needs: { generation: %i[structured_output], judgement: %i[judge] }, consent: :family,
                         sends: %i[transaction_names transaction_amounts provider_category_hints category_names] },
    shadow_categorize: { lane: :background,  shadow_of: :categorize,            consent: :family },
    detect_merchants:  { lane: :background,  needs: %i[structured_output],      consent: :family,
                         sends: %i[transaction_names merchant_names] },
    enhance_merchants: { lane: :background,  needs: %i[structured_output], consent_as: :detect_merchants, consent: :family,
                         sends: %i[merchant_names] }
  }.freeze

  # Each lane's queue. Until PR 4 brings the three lane queues and the ai_chat capsule, lanes
  # map onto today's two: interactive work first, as chat is today.
  QUEUES = { interactive: "ai_high_priority", prompt: "ai_low_priority", background: "ai_low_priority" }.freeze

  module_function

  def features = MATRIX.keys

  def fetch(feature) = MATRIX.fetch(feature.to_sym)

  def queue_for(feature) = QUEUES.fetch(fetch(feature)[:lane])

  # The feature whose route and needs this one uses: a shadow's primary, or search's `embed`.
  def source_of(feature) = fetch(feature).values_at(:shadow_of, :route_of).compact.first || feature.to_sym

  def needs_for(feature) = fetch(source_of(feature)).fetch(:needs)

  # A shadow has its own consent (section 8.2); `consent_as:` puts a feature under another's row.
  def consent_key(feature) = fetch(feature)[:consent_as] || feature.to_sym

  # The consent row a person sees the feature under: a shadow shows under its primary's row.
  # Routing (`route_of:`) doesn't move a feature to another row; only `consent_as:` does.
  def row_key(feature) = consent_key(fetch(feature)[:shadow_of] || feature)

  # The consent rows on the AI features page (PR 7), one per thing a person recognises.
  def consent_keys = features.reject { fetch(_1)[:shadow_of] }.map { consent_key(_1) }.uniq

  # Everything sent under one consent key, so a row's manifest covers its whole group.
  def sends_for(key)
    MATRIX.select { |feature, _| consent_key(feature) == key.to_sym }
          .flat_map { |feature, spec| spec[:sends] || fetch(spec[:shadow_of])[:sends] }
          .uniq
  end

  # The routing and manifest table in docs/llm-guides/ai-pipeline.md (bin/rails ai:routes_doc).
  def doc_table
    rows = MATRIX.map do |feature, spec|
      needs = Ai::Routes.needs_for(feature)
      needs = needs.is_a?(Hash) ? needs.map { |kind, list| "#{kind}: #{list.join(", ")}" }.join("; ") : needs.join(", ")
      row = I18n.t("ai.consent_rows.#{row_key(feature)}")
      row += " (shadow runs)" if spec[:shadow_of]
      sends = Array(spec[:sends] || fetch(spec[:shadow_of])[:sends]).map { I18n.t("ai.sends.#{_1}", locale: :en) }.join("; ")
      "| `#{feature}` | #{spec[:lane]} | #{needs} | #{row} (#{spec[:consent]}) | #{sends} |"
    end
    ([ "| Feature | Lane | Needs | Consent row | Sends |", "|---|---|---|---|---|" ] + rows).join("\n")
  end
end
