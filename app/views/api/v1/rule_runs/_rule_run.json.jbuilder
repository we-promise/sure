# frozen_string_literal: true

json.id rule_run.id
json.rule_id rule_run.rule_id
json.rule_name rule_run.rule_name
json.execution_type rule_run.execution_type
json.status rule_run.status
json.transactions_queued rule_run.transactions_queued
json.transactions_processed rule_run.transactions_processed
json.transactions_modified rule_run.transactions_modified
json.pending_jobs_count rule_run.pending_jobs_count
json.executed_at rule_run.executed_at.iso8601
json.error_message rule_run.error_message

if rule_run.rule
  json.rule do
    json.id rule_run.rule.id
    json.name rule_run.rule.name
    json.resource_type rule_run.rule.resource_type
    json.active rule_run.rule.active
  end
else
  json.rule nil
end

json.created_at rule_run.created_at.iso8601
json.updated_at rule_run.updated_at.iso8601
