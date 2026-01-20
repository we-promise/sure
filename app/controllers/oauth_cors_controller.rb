# frozen_string_literal: true

class OauthCorsController < ApplicationController
  skip_authentication
  skip_before_action :verify_authenticity_token

  def options
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    response.headers["Access-Control-Max-Age"] = "86400"
    head :no_content
  end
end
