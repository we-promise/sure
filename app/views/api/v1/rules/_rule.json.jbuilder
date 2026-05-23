# frozen_string_literal: true

json.id rule.id
json.name rule.name
json.resource_type rule.resource_type
json.active rule.active
json.effective_date rule.effective_date&.iso8601
json.conditions rule.conditions.select { |condition| condition.parent_id.nil? } do |condition|
  json.partial! "api/v1/rules/condition", condition: condition
end
json.actions rule.actions do |action|
  json.partial! "api/v1/rules/action", action: action
end
json.created_at rule.created_at.iso8601
json.updated_at rule.updated_at.iso8601
