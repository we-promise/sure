module EmailAlert::Parsers
  ALL = [
    EmailAlert::Parsers::Gtbank,
    EmailAlert::Parsers::Opay,
    EmailAlert::Parsers::Grey
  ].freeze

  def self.for_domain(domain)
    ALL.find { |parser| parser.handles_domain?(domain) }
  end

  def self.supported_institutions
    ALL.map(&:institution_name)
  end
end
