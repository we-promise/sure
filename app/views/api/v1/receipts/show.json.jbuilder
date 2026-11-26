# frozen_string_literal: true

json.id @scan.id
json.status @scan.status
json.account_id @scan.account_id
json.transaction_id @scan.transaction_id
json.review_reasons @scan.review_reasons
json.created_at @scan.created_at.iso8601
json.updated_at @scan.updated_at.iso8601
