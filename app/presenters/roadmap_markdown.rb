require "uri"

class RoadmapMarkdown
  FORMAT_MARKER = "<!-- roadmap:v1 -->"
  STATUSES = %w[in_progress planned exploring].freeze

  Item = Data.define(:title, :description, :status, :issue_url)
  Phase = Data.define(:name, :description, :items)

  def self.load(path, logger: Rails.logger)
    new(File.read(path), logger: logger).parse
  rescue SystemCallError => error
    logger&.warn("RoadmapMarkdown could not read #{path}: #{error.message}")
    []
  end

  def initialize(markdown, logger: Rails.logger)
    @markdown = markdown
    @logger = logger
  end

  def parse
    unless @markdown.include?(FORMAT_MARKER)
      warn("missing #{FORMAT_MARKER}")
      return []
    end

    phases = []
    phase = nil
    item = nil

    @markdown.each_line do |line|
      line = line.strip

      if (match = line.match(/\A## Phase: (.+)\z/))
        item = finish_item(item, phase)
        phase = { name: match[1].strip, description: nil, items: [] }
        phases << phase
      elsif (match = line.match(/\A### Item: (.+)\z/))
        item = finish_item(item, phase)
        if phase
          item = { title: match[1].strip, description: nil, status: nil, issue_url: nil }
        else
          warn("item #{match[1].strip.inspect} appears before a phase; skipped")
        end
      elsif phase && (match = line.match(/\ADescription: (.+)\z/))
        (item || phase)[:description] = match[1].strip
      elsif item && (match = line.match(/\AStatus: (.+)\z/))
        item[:status] = match[1].strip
      elsif item && (match = line.match(/\AIssue: \[[^\]]+\]\(([^)]+)\)\z/))
        item[:issue_url] = valid_issue_url(match[1].strip)
      elsif line.match?(/\A(?:Status|Issue):/) || line.match?(/\A(?:##|###)\s/)
        warn("unrecognized roadmap metadata: #{line.inspect}") unless line.empty?
      end
    end

    finish_item(item, phase)
    phases.filter_map do |candidate|
      if candidate[:name].present? && candidate[:description].present?
        Phase.new(candidate[:name], candidate[:description], candidate[:items].freeze)
      else
        warn("phase #{candidate[:name].inspect} is missing a description; skipped")
        nil
      end
    end.freeze
  end

  private
    def finish_item(item, phase)
      return nil unless item

      if phase && item[:title].present? && item[:description].present? && STATUSES.include?(item[:status])
        phase[:items] << Item.new(item[:title], item[:description], item[:status].to_sym, item[:issue_url])
      else
        warn("item #{item[:title].inspect} is missing valid metadata; skipped")
      end
      nil
    end

    def valid_issue_url(url)
      uri = URI.parse(url)
      return url if uri.is_a?(URI::HTTP) && uri.scheme == "https" && uri.host == "github.com"

      warn("invalid GitHub issue URL #{url.inspect}; omitted")
      nil
    rescue URI::InvalidURIError
      warn("invalid GitHub issue URL #{url.inspect}; omitted")
      nil
    end

    def warn(message)
      @logger&.warn("RoadmapMarkdown: #{message}")
    end
end
