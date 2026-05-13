# frozen_string_literal: true

module UuidFormat
  PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze

  module_function

  def valid?(value)
    PATTERN.match?(value.to_s)
  end
end
