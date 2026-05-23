# frozen_string_literal: true

mapping_summary = lambda do |type, key|
  mapping = @row_mapping_lookup[[ type, key.to_s ]]

  if mapping
    mappable = if mapping.mappable
      {
        id: mapping.mappable.id,
        type: mapping.mappable_type,
        name: mapping.mappable.try(:name)
      }
    end

    {
      key: mapping.key,
      type: mapping.type,
      value: mapping.value,
      create_when_empty: mapping.create_when_empty,
      creatable: mapping.creatable?,
      mappable: mappable
    }
  else
    {
      key: key,
      type: type,
      value: nil,
      create_when_empty: false,
      creatable: false,
      mappable: nil
    }
  end
end

json.data do
  json.array! @rows do |row|
    json.id row.id
    json.row_number row.source_row_number
    json.valid row.errors.empty?
    json.errors row.errors.full_messages

    json.fields do
      json.account row.account
      json.date row.date
      json.qty row.qty
      json.ticker row.ticker
      json.exchange_operating_mic row.exchange_operating_mic
      json.price row.price
      json.amount row.amount
      json.currency row.currency
      json.name row.name
      json.category row.category
      json.tags row.tags
      json.entity_type row.entity_type
      json.notes row.notes
      json.active row.active
      json.effective_date row.effective_date
      json.conditions row.conditions
      json.actions row.actions
    end

    json.mappings do
      json.account mapping_summary.call("Import::AccountMapping", row.account) if row.account.present?
      json.category mapping_summary.call("Import::CategoryMapping", row.category) if row.category.present?
      json.account_type mapping_summary.call("Import::AccountTypeMapping", row.entity_type) if row.entity_type.present?
      json.tags row.tags_list.reject(&:blank?).map { |tag| mapping_summary.call("Import::TagMapping", tag) }
    end
  end
end

json.meta do
  json.current_page @pagy.page
  json.next_page @pagy.next
  json.prev_page @pagy.prev
  json.total_pages @pagy.pages
  json.total_count @pagy.count
  json.per_page @per_page
end
