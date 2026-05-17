# frozen_string_literal: true

module BankdataImport
  class MerchantResolver
    def initialize(family)
      @family = family
    end

    def resolve(name)
      normalized = name.to_s.strip
      return nil if normalized.blank?

      family.merchants.find_or_create_by!(name: normalized)
    end

    private
      attr_reader :family
  end
end
