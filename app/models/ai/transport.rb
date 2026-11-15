# Thin adapters over RubyLLM, one per protocol. Everything above a transport sees
# Ai::Config values, Ai::Tokens and Ai::Error, never a client library's types.
module Ai::Transport
  def self.for(endpoint)
    case endpoint.protocol
    when :compatible then Ai::Transport::Compatible.new(endpoint)
    when :anthropic then Ai::Transport::Anthropic.new(endpoint)
    else raise ArgumentError, "no transport for the #{endpoint.protocol} protocol"
    end
  end
end
