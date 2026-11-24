# frozen_string_literal: true

json.security_id @security.id
json.currency @result.currency
json.created @result.created
json.updated @result.updated
json.start_date @result.start_date.iso8601
json.end_date @result.end_date.iso8601
