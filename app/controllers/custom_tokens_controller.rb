# frozen_string_literal: true

class CustomTokensController < Doorkeeper::TokensController
  after_action :set_cors_headers

  private

    def set_cors_headers
      response.headers["Access-Control-Allow-Origin"] = "*"
      response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
      response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
      response.headers["Access-Control-Max-Age"] = "86400"
    end
end
