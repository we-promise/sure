# frozen_string_literal: true

json.data do
  json.rule_run_id @rule_run.id
  json.status @rule_run.status
  json.transactions_queued @rule_run.transactions_queued
  json.transactions_awaiting_ai @rule_run.transactions_awaiting_ai
  json.transactions_modified @rule_run.transactions_modified
  json.finished @rule_run.finished?
  json.updated_at @rule_run.updated_at.iso8601
end
