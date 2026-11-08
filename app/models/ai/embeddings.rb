# Embeddings for the vector store: `index` for a document's chunks (`embed`) and
# `query` for a search (`search_documents`, recorded under its own feature). Both run the first
# embedding model on the `embed` route, with no failover: a vector from another model doesn't
# compare with the stored ones. An `embed` route on an OpenAI vector store has no
# embedding model here; the store embeds for itself.
module Ai::Embeddings
  BATCH_SIZE = 50   # VectorStore::Embeddable's EMBED_BATCH_SIZE

  module_function

  def index(texts, family:, user: nil)
    model = model_for(:embed, family:, user:)
    Array(texts).each_slice(BATCH_SIZE).flat_map do |slice|
      embed(model, :embed, family, slice, "RETRIEVAL_DOCUMENT")
    end
  end

  def query(text, family:, user: nil)
    embed(model_for(:search_documents, family:, user:), :search_documents, family, [ text ], "RETRIEVAL_QUERY").first
  end

  # The embedding model the route sends to, or Ai::Error::Unavailable with the router's reason.
  def model_for(feature, family:, user: nil)
    plan = Ai::Router.new(family:, user:).resolve(feature)
    raise Ai::Error::Unavailable, plan.reason unless plan.is_a?(Ai::Plan)

    route = plan.routes.find { _1.model.capable?(:embedding) && !_1.endpoint.vector_store? }
    raise Ai::Error::Unavailable, :capability_missing unless route

    route.model
  end

  def embed(model, feature, family, texts, task_type)
    request = Ai::Transport::Base::EmbedRequest.new(feature:, family:, model:, texts:, task_type:)
    Ai::Transport.for(model.endpoint).embed(request).vectors
  end
end
