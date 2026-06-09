class MerchantImport < Import
  def import!
    transaction do
      rows.each do |row|
        merchant_name = row.name.to_s.strip
        next if merchant_name.blank?

        merchant = family.merchants.find_or_initialize_by(name: merchant_name)
        next unless merchant.new_record?

        merchant.color = row.merchant_color.presence || FamilyMerchant::COLORS.sample
        merchant.website_url = row.merchant_website.presence
        merchant.save!
      end
    end
  end

  def column_keys
    %i[name merchant_color merchant_website]
  end

  def required_column_keys
    %i[name]
  end

  def mapping_steps
    []
  end

  def dry_run
    { merchants: rows_count }
  end

  def csv_template
    template = <<-CSV
      name*,color,website_url
      Coffee Shop,#e99537,https://coffeeshop.com
      Pizza Palace,#4da568,https://pizzapalace.com
      Bookstore,,
    CSV

    CSV.parse(template, headers: true)
  end

  def generate_rows_from_csv
    rows.destroy_all

    validate_required_headers!

    name_header = header_for("name")
    color_header = header_for("color")
    website_header = header_for("website_url", "website url", "website")

    csv_rows.each.with_index(1) do |row, index|
      rows.create!(
        source_row_number: index,
        name: row[name_header].to_s.strip,
        merchant_color: row[color_header].to_s.strip,
        merchant_website: row[website_header].to_s.strip,
        currency: default_currency
      )
    end
  end

  private
    def validate_required_headers!
      missing_headers = required_column_keys.map(&:to_s).reject { |key| header_for(key).present? }
      return if missing_headers.empty?

      errors.add(:base, :missing_columns, columns: missing_headers.join(", "))
      raise ActiveRecord::RecordInvalid.new(self)
    end

    def header_for(*candidates)
      candidates.each do |candidate|
        normalized = normalize_header(candidate)
        header = normalized_headers[normalized]
        return header if header.present?
      end

      nil
    end

    def normalized_headers
      @normalized_headers ||= begin
        result = {}
        duplicates = []

        csv_headers.each do |header|
          key = normalize_header(header)
          if result.key?(key)
            duplicates << header
          else
            result[key] = header
          end
        end

        if duplicates.any?
          errors.add(:base, :duplicate_columns, columns: duplicates.join(", "))
          raise ActiveRecord::RecordInvalid.new(self)
        end

        result
      end
    end

    def normalize_header(header)
      header.to_s.strip.downcase.gsub(/\*/, "").gsub(/[\s-]+/, "_")
    end
end
