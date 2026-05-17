# frozen_string_literal: true

module BankdataImport
  SOURCE = "bankdata_pipeline"

  class ValidationError < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super(errors.join(", "))
    end
  end
end
