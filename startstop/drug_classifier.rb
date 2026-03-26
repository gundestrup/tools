# drug_classifier.rb
# AI-drevet drug class klassifikation via embeddings

require "matrix"
require_relative "drug_ontology"

module DrugClassifier
  EMBEDDINGS_FILE = "drug_embeddings.json"

  # Lazy-load
  def self.embeddings
    @embeddings ||= JSON.parse(File.read(EMBEDDINGS_FILE))
  end

  # Convert embedding array -> vector
  def self.vec(a) = Vector.elements(a.map(&:to_f))

  # Cosine similarity
  def self.cos(a, b)
    (a.inner_product(b)) / (a.r * b.r)
  end

  # Hent embedding, fallback = gennemsnit
  def self.embedding_for(token)
    emb = embeddings[token.downcase]
    return emb if emb
    nil
  end

  # Klassificer tekst til drug classes
  def self.classify(text)
    tokens = text.downcase.scan(/[a-zæøå\-]+/)
    token_vecs = tokens.map { |t| embedding_for(t) }.compact
    return [] if token_vecs.empty?

    avg_vec = vec(token_vecs.flatten.each_slice(token_vecs.first.size).map(&:first))

    DrugOntology::CLASSES.select do |klass, terms|
      terms.any? do |t|
        emb = embedding_for(t)
        next false unless emb
        cos(vec(emb), avg_vec) > 0.75
      end
    end.keys
  end
end
