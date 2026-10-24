require "test_helper"

class Icost::NormalizerTest < ActiveSupport::TestCase
  test "preserves all export fields and normalizes exact money without losing category hierarchy" do
    result = normalize("金额" => "-1234.5678", "二级分类" => "合成子类", "备注" => "  合成备注\n第二行  ", "标签" => "#合成#演示", "图片链接1" => "https://example.invalid/synthetic.png")
    fields = result[:attributes]

    assert_empty result[:issues]
    assert_equal "-1234.5678", fields[:amount]
    assert_equal [ "合成主类", "合成子类" ], fields[:category_path]
    assert_equal "  合成备注\n第二行  ", fields[:note]
    assert_equal [ "合成", "演示" ], fields[:tags]
    assert_equal "https://example.invalid/synthetic.png", fields[:image_references]["图片链接1"]
    assert_equal Icost::Normalizer::HEADERS.sort, fields[:raw_fields].keys.sort
  end

  test "retains missing and unknown fields including duplicate column values" do
    result = Icost::Normalizer.call(headers: [ "日期", "未知字段", "未知字段", "" ], values: [ "2026/09/01", "one", "two", "blank header", "extra cell" ])

    assert_includes result[:issues], "missing_required_header"
    assert_equal [ "one", "two" ], result[:attributes][:unknown_fields]["未知字段"]
    assert_equal "blank header", result[:attributes][:unknown_fields]["__column_4"]
    assert_equal "extra cell", result[:attributes][:unknown_fields]["__column_5"]
    assert_nil result[:attributes][:amount]
  end

  test "duplicate known columns remain reviewable rather than selecting a value" do
    result = Icost::Normalizer.call(headers: Icost::Normalizer::HEADERS + [ "金额" ], values: values + [ "-2.00" ])

    assert_includes result[:issues], "duplicate_known_header"
    assert_equal [ "-12.30", "-2.00" ], result[:attributes][:raw_fields]["金额"]
    assert_nil result[:attributes][:amount]
  end

  test "amount precision is retained and flagged before a ledger can round it" do
    %w[-0.00001 -1000000000000000.0001].each do |amount|
      result = normalize("金额" => amount)
      assert_equal amount, result[:attributes][:amount]
      assert_includes result[:issues], "amount_precision_unsupported"
    end
    result = normalize("退款" => "0.123456789")
    assert_equal "0.123456789", result[:attributes][:refund_amount]
    assert_includes result[:issues], "refund_semantics_required"
    refute_includes result[:issues], "amount_precision_unsupported"
  end

  test "rejects nonfinite exponent and ambiguous localized money" do
    [ "NaN", "Infinity", "1e3", "1,23", "1,234.56", "=1+2", true ].each do |amount|
      result = normalize("金额" => amount)
      assert_nil result[:attributes][:amount]
      assert_includes result[:issues], "amount_invalid"
    end
  end

  test "uses source signs and preserves currencies separately" do
    %w[CNY EUR TWD USD TRY JPY].each do |currency|
      result = normalize("货币" => currency)
      assert_empty result[:issues]
      assert_equal currency, result[:attributes][:currency]
    end
    assert_includes normalize("金额" => "12.30")[:issues], "amount_type_mismatch"
    assert_includes normalize("类型" => "收入")[:issues], "amount_type_mismatch"
    assert_empty normalize("类型" => "收入", "金额" => "12.30")[:issues]
    assert_includes normalize("货币" => "eur")[:issues], "currency_invalid"
  end

  test "keeps timestamp precision and rejects invalid or timezone-ambiguous input" do
    result = normalize("日期" => "2026/09/01 23:59:58")
    assert_equal "2026/09/01 23:59:58", result[:attributes][:recorded_at_text]
    assert_empty result[:issues]
    [ "2026/02/30 12:00:00", "2026/01/01 24:00:00", "2026/01/01 23:60:00", "2026-09-01T12:00:00Z", "46266.5", "09/01/2026", "2026/09-01", "0000/01/01" ].each do |date|
      assert_includes normalize("日期" => date)[:issues], "date_invalid"
    end
    assert_empty normalize("日期" => "2024-02-29")[:issues]
  end

  test "special records require facts rather than invented accounting relationships" do
    transfer = normalize("类型" => "转账", "账户2" => "合成目标账户")
    assert_includes transfer[:issues], "transfer_direction_required"
    refute_includes transfer[:issues], "counterparty_required"
    installment = normalize("类型" => "转账", "一级分类" => "分期创建")
    assert_includes installment[:issues], "installment_details_required"
    assert_includes installment[:issues], "counterparty_required"
    assert_includes normalize("类型" => "退款入账", "金额" => "12.30")[:issues], "refund_link_required"
    assert_includes normalize("退款" => "2.10")[:issues], "refund_semantics_required"
    assert_includes normalize("优惠" => "0.10")[:issues], "discount_semantics_required"
    assert_includes normalize("手续费" => "0.10")[:issues], "fee_semantics_required"
    assert_includes normalize("账户1" => "")[:issues], "account_required"
  end

  test "never geocodes location text or assigns a coordinate reference system" do
    result = normalize("位置" => "合成地点（30.25, 120.50）")
    assert_equal "合成地点（30.25, 120.50）", result[:attributes][:location_text]
    assert_nil result[:attributes][:latitude]
    assert_nil result[:attributes][:longitude]
    assert_equal "unknown", result[:attributes][:coordinate_system]
  end

  test "accepts explicit coordinates without assigning WGS84 and validates ranges" do
    result = normalize("纬度" => "30.123456789", "经度" => "120.50000")
    assert_empty result[:issues]
    assert_equal "30.123456789", result[:attributes][:latitude]
    assert_equal "120.5", result[:attributes][:longitude]
    assert_equal "unknown", result[:attributes][:coordinate_system]
    assert_equal "GCJ-02", normalize("纬度" => "0", "经度" => "0", "坐标系" => "GCJ-02")[:attributes][:coordinate_system]
    [ { "纬度" => "91", "经度" => "0" }, { "纬度" => "0", "经度" => "-181" }, { "纬度" => "NaN", "经度" => "0" } ].each do |coordinates|
      assert_includes normalize(coordinates)[:issues], "coordinate_invalid"
    end
    assert_includes normalize("纬度" => "30")[:issues], "coordinate_pair_required"
    assert_empty normalize("纬度" => "-90", "经度" => "180")[:issues]
  end

  private

    def values
      Icost::Normalizer::HEADERS.map do |header|
        { "日期" => "2026/09/01 12:00:00", "类型" => "支出", "金额" => "-12.30", "一级分类" => "合成主类", "账户1" => "合成账户", "货币" => "CNY", "账本" => "合成账本" }.fetch(header, nil)
      end
    end

    def normalize(overrides = {})
      source = Icost::Normalizer::HEADERS.zip(values).to_h.merge(overrides)
      Icost::Normalizer.call(headers: source.keys, values: source.values)
    end
end
