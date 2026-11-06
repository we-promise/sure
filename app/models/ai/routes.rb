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
    extract_pdf:       { lane: :prompt,      needs: %i[structured_output],      consent: :user,   # vision, documents, ocr: per way of reading (2e)
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

  module_function

  def features = MATRIX.keys

  def fetch(feature) = MATRIX.fetch(feature.to_sym)

  # The feature whose route and needs this one uses: a shadow's primary, or search's `embed`.
  def source_of(feature) = fetch(feature).values_at(:shadow_of, :route_of).compact.first || feature.to_sym

  def needs_for(feature) = fetch(source_of(feature)).fetch(:needs)

  # A shadow has its own consent (section 8.2); `consent_as:` puts a feature under another's row.
  def consent_key(feature) = fetch(feature)[:consent_as] || feature.to_sym

  # The consent rows on the AI features page (PR 7), one per thing a person recognises.
  def consent_keys = features.reject { fetch(_1)[:shadow_of] }.map { consent_key(_1) }.uniq

  # Everything sent under one consent key, so a row's manifest covers its whole group.
  def sends_for(key)
    MATRIX.select { |feature, _| consent_key(feature) == key.to_sym }
          .flat_map { |feature, spec| spec[:sends] || fetch(spec[:shadow_of])[:sends] }
          .uniq
  end
end
