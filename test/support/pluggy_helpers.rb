# frozen_string_literal: true

module PluggyHelpers
  def stub_pluggy_response(code:, body:)
    OpenStruct.new(code: code, body: body.to_json, parsed_response: body, success?: code == 200)
  end
end
