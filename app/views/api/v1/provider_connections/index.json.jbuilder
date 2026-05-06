# frozen_string_literal: true

json.data do
  json.array! @provider_connections, partial: "api/v1/provider_connections/provider_connection", as: :provider_connection
end
