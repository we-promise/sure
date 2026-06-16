module Brazil
  class Bank < ApplicationRecord
    self.table_name = "brazil_banks"

    has_many :accounts, foreign_key: :brazil_bank_id, dependent: :nullify

    before_validation :normalize_fields
    before_validation :assign_searchable_text

    validates :ispb, :name, :short_name, presence: true
    validates :ispb, uniqueness: true

    scope :ordered, -> { order(Arel.sql("LOWER(short_name) ASC"), :code, :ispb) }
    scope :displayable, -> {
      where(display_in_account_selector: true)
        .where.not(code: [ nil, "", "n/a", "N/A" ])
        .ordered
    }
    scope :search, ->(query) {
      normalized_query = normalize_for_search(query)

      if normalized_query.blank?
        ordered
      else
        where("searchable_text LIKE ?", "%#{sanitize_sql_like(normalized_query)}%").ordered
      end
    }

    def self.normalize_for_search(value)
      I18n.transliterate(value.to_s).downcase.squish
    end

    def selector_label
      [ short_name, code.presence, "ISPB #{ispb}" ].compact.join(" - ")
    end

    def logo_url
      Brazil::BankLogoResolver.new(self).asset_path
    end

    private

      def normalize_fields
        self.ispb = ispb.to_s.strip.presence
        self.code = code.to_s.strip.presence
        self.name = normalize_name(name)
        self.short_name = normalize_name(short_name.presence || name)
        self.logo_key = logo_key.to_s.strip.presence&.parameterize
      end

      def normalize_name(value)
        value.to_s.squish.then { |name| name.present? ? name.titleize : nil }
      end

      def assign_searchable_text
        self.searchable_text = self.class.normalize_for_search(
          [ ispb, code, name, short_name ].compact.join(" ")
        )
      end
  end
end
