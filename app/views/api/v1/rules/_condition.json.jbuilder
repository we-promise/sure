# frozen_string_literal: true

json.id condition.id
json.condition_type condition.condition_type
json.operator condition.operator
json.value condition.value

if condition.compound?
  json.sub_conditions condition.sub_conditions do |sub_condition|
    json.partial! "api/v1/rules/condition", condition: sub_condition
  end
else
  json.sub_conditions []
end

json.created_at condition.created_at.iso8601
json.updated_at condition.updated_at.iso8601
