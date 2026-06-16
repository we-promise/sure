require "csv"

module Brazil
  class BankCatalogImporter
    SOURCE_URL = "https://www.bcb.gov.br/pom/spb/ing/ParticipantesSTRIng.csv"

    CURATED_LOGO_KEYS = {
      "001" => "banco-do-brasil",
      "003" => "banco-da-amazonia",
      "004" => "banco-do-nordeste",
      "033" => "santander",
      "041" => "banrisul",
      "070" => "brb",
      "077" => "inter",
      "104" => "caixa",
      "121" => "agibank",
      "208" => "btg-pactual",
      "212" => "banco-original",
      "218" => "bs2",
      "237" => "bradesco",
      "260" => "nubank",
      "290" => "pagbank",
      "318" => "bmg",
      "323" => "mercado-pago",
      "336" => "c6-bank",
      "341" => "itau",
      "380" => "picpay",
      "389" => "mercantil",
      "422" => "safra",
      "623" => "pan",
      "633" => "rendimento",
      "637" => "sofisa",
      "655" => "votorantim",
      "707" => "daycoval",
      "739" => "cetelem",
      "745" => "citibank",
      "756" => "sicoob",
      "748" => "sicredi"
    }.freeze

    INFRASTRUCTURE_NAME_PATTERNS = [
      "BANCO CENTRAL",
      "SECRETARIA DO TESOURO",
      "SELIC",
      "CIP",
      "CAMARA INTERBANCARIA",
      "B3 S.A.",
      "BM&FBOVESPA",
      "CETIP"
    ].freeze

    attr_reader :text, :source, :source_updated_on

    def initialize(text:, source: SOURCE_URL, source_updated_on: Date.current)
      @text = text.to_s
      @source = source
      @source_updated_on = source_updated_on
    end

    def call
      rows.sum do |attributes|
        upsert_bank(attributes)
        1
      end
    end

    private

      def rows
        csv_rows.filter_map do |row|
          attributes_for(row)
        end
      end

      def csv_rows
        CSV.parse(text, headers: true, col_sep: detect_column_separator, liberal_parsing: true)
      end

      def detect_column_separator
        first_line = text.lines.find { |line| line.strip.present? }.to_s
        first_line.count(";") >= first_line.count(",") ? ";" : ","
      end

      def attributes_for(row)
        ispb = field(row, "ISPB")
        return if ispb.blank?

        code = field(row, "Numero_Codigo", "Numero-Codigo", "Code_Number", "Number_Code", "Número-Código")
        short_name = curated_short_name(code, field(row, "Nome_Reduzido", "Short_Name", "Nome Reduzido"))
        name = field(row, "Nome_Extenso", "Full_Name", "Nome Extenso")

        {
          ispb: ispb,
          code: code,
          short_name: short_name,
          name: name.presence || short_name,
          participates_in_compe: truthy?(field(row, "Participa_da_Compe", "Participates_in_Compe", "Participa da Compe")),
          access_kind: field(row, "Acesso", "Acesso_Principal", "Main_Access", "Acesso principal"),
          started_on: parse_date(field(row, "Inicio_Operacao", "Inicio da Operacao", "Start_Date", "Início da Operação")),
          source: source,
          source_updated_on: source_updated_on,
          logo_key: CURATED_LOGO_KEYS[code],
          display_in_account_selector: displayable?(code, name, short_name)
        }
      end

      def field(row, *names)
        names.each do |name|
          value = row[name]
          return value.to_s.squish.presence if value.present?
        end

        normalized_headers = row.headers.index_by { |header| normalize_header(header) }
        names.each do |name|
          header = normalized_headers[normalize_header(name)]
          value = row[header] if header.present?
          return value.to_s.squish.presence if value.present?
        end

        nil
      end

      def upsert_bank(attributes)
        bank = Brazil::Bank.find_or_initialize_by(ispb: attributes[:ispb])
        bank.assign_attributes(attributes)
        bank.save!
      end

      def normalize_header(value)
        I18n.transliterate(value.to_s).downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
      end

      def displayable?(code, *names)
        return false if code.blank? || code.to_s.casecmp("n/a").zero?

        normalized_name = I18n.transliterate(names.compact.join(" ")).upcase
        INFRASTRUCTURE_NAME_PATTERNS.none? { |pattern| normalized_name.include?(pattern) }
      end

      def truthy?(value)
        value.to_s.casecmp("sim").zero? || value.to_s.casecmp("yes").zero? || value.to_s == "1"
      end

      def parse_date(value)
        Date.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def curated_short_name(code, fallback)
        case code
        when "001" then "Banco do Brasil"
        when "033" then "Santander"
        when "104" then "Caixa"
        when "237" then "Bradesco"
        when "260" then "Nubank"
        when "341" then "Itau"
        else fallback
        end
      end
  end
end
