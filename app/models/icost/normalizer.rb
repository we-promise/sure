require "bigdecimal"
require "date"

module Icost
  # Normalized fields are a projection. raw_fields and the caller's source values
  # retain the export, including fields whose accounting meaning is unknown.
  class Normalizer
    HEADERS = %w[日期 类型 金额 一级分类 二级分类 账户1 账户2 备注 货币 标签 账本 位置 退款 优惠 手续费 图片链接1 图片链接2 图片链接3 图片附件1 图片附件2 图片附件3].freeze
    COORDINATE_HEADERS = %w[纬度 经度 坐标系].freeze
    KNOWN_HEADERS = (HEADERS + COORDINATE_HEADERS).freeze
    REQUIRED_HEADERS = %w[日期 类型 金额 货币 账户1 一级分类].freeze
    MONEY_PATTERN = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/
    DATE_PATTERN = /\A(\d{4})([\/-])(\d{2})\2(\d{2})(?:[ T](\d{2}):(\d{2}):(\d{2}))?\z/

    def self.call(headers:, values:)
      new(headers, values).call
    end

    def initialize(headers, values)
      @headers = headers
      @values = values
      @issues = []
      @fields = {}
      @raw_fields = {}
      @unknown_fields = {}
    end

    def call
      collect_fields
      attributes = {
        recorded_at_text: text("日期"),
        transaction_type: trimmed("类型"),
        amount: decimal("金额", required: true),
        currency: trimmed("货币"),
        category_path: [ text("一级分类"), text("二级分类") ],
        account_name: text("账户1"),
        counterparty_name: text("账户2"),
        book_name: text("账本"),
        note: text("备注"),
        tags: parse_tags,
        location_text: text("位置"),
        latitude: coordinate("纬度", 90),
        longitude: coordinate("经度", 180),
        coordinate_system: trimmed("坐标系").empty? ? "unknown" : text("坐标系"),
        refund_amount: decimal("退款"),
        discount_amount: decimal("优惠"),
        fee_amount: decimal("手续费"),
        image_references: HEADERS.grep(/\A图片/).to_h { |header| [ header, @fields[header] ] },
        raw_fields: @raw_fields,
        unknown_fields: @unknown_fields
      }
      validate_record(attributes)
      { attributes: attributes, issues: @issues.uniq }
    end

    private

      def collect_fields
        width = [ @headers.size, @values.size ].max
        width.times do |index|
          header = @headers[index].to_s
          value = @values[index]
          key = header.empty? ? "__column_#{index + 1}" : header
          if @raw_fields.key?(key)
            @raw_fields[key] = [ @raw_fields[key] ] unless @raw_fields[key].is_a?(Array)
            @raw_fields[key] << value
          else
            @raw_fields[key] = value
          end
        end
        @headers.tally.each do |header, count|
          next unless KNOWN_HEADERS.include?(header)
          if count > 1
            @issues << "duplicate_known_header"
          else
            @fields[header] = @raw_fields[header]
          end
        end
        @unknown_fields = @raw_fields.reject { |header, _value| KNOWN_HEADERS.include?(header) }
        @issues << "missing_required_header" unless (REQUIRED_HEADERS - @headers).empty?
      end

      def text(header)
        value = @fields[header]
        value.nil? ? "" : value.to_s
      end

      def trimmed(header)
        text(header).strip
      end

      def parse_tags
        text("标签").split("#").map(&:strip).reject(&:empty?).uniq
      end

      def decimal(header, required: false)
        value = trimmed(header)
        if value.empty?
          @issues << "amount_required" if required
          return nil
        end
        unless MONEY_PATTERN.match?(value)
          @issues << (header == "金额" ? "amount_invalid" : "adjustment_invalid")
          return nil
        end
        number = BigDecimal(value)
        normalized = number.to_s("F")
        integer, fraction = normalized.delete_prefix("-").split(".")
        if header == "金额" && (integer.size > 15 || fraction.to_s.sub(/0+\z/, "").size > 4)
          @issues << "amount_precision_unsupported"
        end
        normalized
      end

      def coordinate(header, limit)
        value = trimmed(header)
        return nil if value.empty?

        unless MONEY_PATTERN.match?(value)
          @issues << "coordinate_invalid"
          return nil
        end
        number = BigDecimal(value)
        if number.abs > limit
          @issues << "coordinate_invalid"
          return nil
        end
        number.to_s("F")
      end

      def validate_record(attributes)
        validate_date
        @issues << "currency_invalid" unless /\A[A-Z]{3}\z/.match?(attributes[:currency])
        @issues << "account_required" if attributes[:account_name].strip.empty?
        @issues << "category_required" if attributes[:category_path].first.strip.empty?
        @issues << "coordinate_pair_required" if attributes[:latitude].nil? != attributes[:longitude].nil?

        case attributes[:transaction_type]
        when "支出", "收入"
          amount = attributes[:amount] && BigDecimal(attributes[:amount])
          if amount && ((attributes[:transaction_type] == "支出" && amount.positive?) || (attributes[:transaction_type] == "收入" && amount.negative?))
            @issues << "amount_type_mismatch"
          end
        when "转账"
          @issues << "transfer_direction_required"
          @issues << "counterparty_required" if attributes[:counterparty_name].strip.empty?
          @issues << "installment_details_required" if attributes[:category_path].any? { |value| value.include?("分期") }
        when "退款入账"
          @issues << "refund_link_required"
        else
          @issues << "transaction_type_unsupported"
        end

        { refund_amount: "refund_semantics_required", discount_amount: "discount_semantics_required", fee_amount: "fee_semantics_required" }.each do |field, issue|
          @issues << issue if attributes[field] && !BigDecimal(attributes[field]).zero?
        end
      end

      def validate_date
        match = DATE_PATTERN.match(trimmed("日期"))
        valid = match && match[1].to_i.positive? && Date.valid_date?(match[1].to_i, match[3].to_i, match[4].to_i)
        valid &&= match[5].nil? || (match[5].to_i < 24 && match[6].to_i < 60 && match[7].to_i < 60)
        @issues << "date_invalid" unless valid
      end
  end
end
