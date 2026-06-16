module Brazil
  class BankLogoResolver
    attr_reader :bank

    def initialize(bank)
      @bank = bank
    end

    def asset_path
      return bank.logo_path if bank.logo_path.present?
      return if bank.logo_key.blank?

      candidate = "brazil/banks/#{bank.logo_key}.svg"
      return candidate if Rails.root.join("app/assets/images", candidate).exist?

      nil
    end

    def fallback_initials
      words = bank.short_name.to_s
                  .gsub(/[^[:alnum:]\s]/, " ")
                  .squish
                  .split
                  .reject { |word| word.length <= 2 }

      initials = words.first(2).map { |word| word.first.upcase }.join
      initials.presence || bank.short_name.to_s.first(2).upcase
    end
  end
end
