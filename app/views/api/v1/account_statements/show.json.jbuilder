# frozen_string_literal: true

json.data do
  json.partial! "api/v1/account_statements/account_statement", account_statement: @statement
end

json.meta do
  json.duplicate !!@duplicate
end
