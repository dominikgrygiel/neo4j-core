require 'neo4j/core/cypher_session'
require 'neo4j/core/instrumentable'

module Neo4j
  module Core
    class CypherSession
      module Adaptors
        MAP = {}

        class Base
          include Neo4j::Core::Instrumentable

          def connect(*_args)
            fail '#connect not implemented!'
          end

          Query = Struct.new(:cypher, :parameters, :pretty_cypher, :context)

          class QueryBuilder
            attr_reader :queries

            def initialize
              @queries = []
            end

            def append(*args)
              query = case args.map(&:class)
                      when [String], [String, Hash]
                        Query.new(args[0], args[1] || {})
                      when [::Neo4j::Core::Query]
                        args[0]
                      else
                        fail ArgumentError, "Could not determine query from arguments: #{args.inspect}"
                      end

              @queries << query
            end

            def query
              # `nil` sessions are just a workaround until
              # we phase out `Query` objects containing sessions
              Neo4j::Core::Query.new(session: nil)
            end
          end

          def query(*args)
            options = args.size == 3 ? args.pop : {}

            queries(options) { append(*args) }[0]
          end

          def queries(options = {}, &block)
            query_builder = QueryBuilder.new

            query_builder.instance_eval(&block)

            tx = options.delete(:transaction) || self.class.transaction_class.new(self)

            query_set(tx, query_builder.queries, {commit: true}.merge(options))
          end

          [:query_set,
           :version,
           :indexes_for_label,
           :uniqueness_constraints_for_label].each do |method|
            define_method(method) do |*_args|
              fail "##{method} method not implemented on adaptor!"
            end
          end

          # If called without a block, returns a Transaction object
          # which can be used to call query/queries/mark_failed/commit
          # If called with a block, the Transaction object is yielded
          # to the block and `commit` is ensured.  Any uncaught exceptions
          # will mark the transaction as failed first
          def transaction
            return self.class.transaction_class.new(self) if !block_given?

            begin
              tx = transaction

              yield tx
            rescue Exception => e # rubocop:disable Lint/RescueException
              tx.mark_failed

              raise e
            ensure
              tx.close
            end
          end

          EMPTY = ''
          NEWLINE_W_SPACES = "\n  "

          instrument(:query, 'neo4j.core.cypher_query', %w(query)) do |_, _start, _finish, _id, payload|
            query = payload[:query]
            params_string = (query.parameters && query.parameters.size > 0 ? "| #{query.parameters.inspect}" : EMPTY)
            cypher = query.pretty_cypher ? NEWLINE_W_SPACES + query.pretty_cypher.gsub(/\n/, NEWLINE_W_SPACES) : query.cypher

            " #{ANSI::CYAN}#{query.context || 'CYPHER'}#{ANSI::CLEAR} #{cypher} #{params_string}"
          end

          class << self
            def instrument_queries(queries)
              queries.each do |query|
                instrument_query(query) {}
              end
            end

            def transaction_class
              fail '.transaction_class method not implemented on adaptor!'
            end
          end
        end
      end
    end
  end
end
