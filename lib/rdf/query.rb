module RDF
  ##
  # An RDF basic graph pattern (BGP) query.
  #
  # @example Constructing a basic graph pattern query (1)
  #   query = RDF::Query.new do
  #     pattern [:person, RDF.type,  FOAF.Person]
  #     pattern [:person, FOAF.name, :name]
  #     pattern [:person, FOAF.mbox, :email]
  #   end
  #
  # @example Constructing a basic graph pattern query (2)
  #   query = RDF::Query.new({
  #     :person => {
  #       RDF.type  => FOAF.Person,
  #       FOAF.name => :name,
  #       FOAF.mbox => :email,
  #     }
  #   })
  #
  # @example Executing a basic graph pattern query
  #   graph = RDF::Graph.load('etc/doap.nt')
  #   query.execute(graph).each do |solution|
  #     puts solution.inspect
  #   end
  #
  # @example Constructing and executing a query in one go (1)
  #   solutions = RDF::Query.execute(graph) do
  #     pattern [:person, RDF.type, FOAF.Person]
  #   end
  #
  # @example Constructing and executing a query in one go (2)
  #   solutions = RDF::Query.execute(graph, {
  #     :person => {
  #       RDF.type => FOAF.Person,
  #     }
  #   })
  #
  # @since 0.3.0
  class Query
    autoload :Pattern,   'rdf/query/pattern'
    autoload :Solution,  'rdf/query/solution'
    autoload :Solutions, 'rdf/query/solutions'
    autoload :Variable,  'rdf/query/variable'

    ##
    # Executes a query on the given `queryable` graph or repository.
    #
    # @param  [RDF::Queryable] queryable
    #   the graph or repository to query
    # @param  [Hash{Object => Object}] patterns
    #   optional hash patterns to initialize the query with
    # @param  [Hash{Symbol => Object}] options
    #   any additional keyword options (see {RDF::Query#initialize})
    # @yield  [query]
    # @yieldparam  [RDF::Query] query
    # @yieldreturn [void] ignored
    # @return [RDF::Query::Solutions]
    #   the resulting solution sequence
    # @see    RDF::Query#execute
    def self.execute(queryable, patterns = nil, options = {}, &block)
      self.new(patterns, options, &block).execute(queryable, options)
    end

    ##
    # The variables used in this query.
    #
    # @return [Hash{Symbol => RDF::Query::Variable}]
    attr_reader :variables

    ##
    # The patterns that constitute this query.
    #
    # @return [Array<RDF::Query::Pattern>]
    attr_reader :patterns

    ##
    # The solution sequence for this query.
    #
    # @return [RDF::Query::Solutions]
    attr_reader :solutions

    ##
    # Any additional options for this query.
    #
    # @return [Hash]
    attr_reader :options

    ##
    # Initializes a new basic graph pattern query.
    #
    # @overload initialize(patterns = [], options = {})
    #   @param  [Array<RDF::Query::Pattern>] patterns
    #     ...
    #   @param  [Hash{Symbol => Object}] options
    #     any additional keyword options
    #   @option options [RDF::Query::Solutions] :solutions (Solutions.new)
    #   @yield  [query]
    #   @yieldparam  [RDF::Query] query
    #   @yieldreturn [void] ignored
    #
    # @overload initialize(patterns, options = {})
    #   @param  [Hash{Object => Object}] patterns
    #     ...
    #   @param  [Hash{Symbol => Object}] options
    #     any additional keyword options
    #   @option options [RDF::Query::Solutions] :solutions (Solutions.new)
    #   @yield  [query]
    #   @yieldparam  [RDF::Query] query
    #   @yieldreturn [void] ignored
    def initialize(patterns = nil, options = {}, &block)
      @options   = options.dup
      @variables = {}
      @solutions = @options.delete(:solutions) || Solutions.new

      @patterns  = case patterns
        when Hash  then compile_hash_patterns(patterns.dup)
        when Array then patterns
        else []
      end

      if block_given?
        case block.arity
          when 0 then instance_eval(&block)
          else block.call(self)
        end
      end
    end

    ##
    # Appends the given query `pattern` to this query.
    #
    # @param  [RDF::Query::Pattern] pattern
    #   a triple query pattern
    # @return [void] self
    def <<(pattern)
      @patterns << Pattern.from(pattern)
      self
    end

    ##
    # Appends the given query `pattern` to this query.
    #
    # @param  [RDF::Query::Pattern] pattern
    #   a triple query pattern
    # @param  [Hash{Symbol => Object}] options
    #   any additional keyword options
    # @option options [Boolean] :optional (false)
    #   whether this is an optional pattern
    # @return [void] self
    def pattern(pattern, options = {})
      @patterns << Pattern.from(pattern, options)
      self
    end

    ##
    # Returns an optimized copy of this query.
    #
    # @param  [Hash{Symbol => Object}] options
    #   any additional options for optimization
    # @return [RDF::Query] a copy of `self`
    # @since  0.3.0
    def optimize(options = {})
      self.dup.optimize!(options)
    end

    ##
    # Optimizes this query by reordering its constituent triple patterns
    # according to their cost estimates.
    #
    # @param  [Hash{Symbol => Object}] options
    #   any additional options for optimization
    # @return [void] `self`
    # @see    RDF::Query::Pattern#cost
    # @since  0.3.0
    def optimize!(options = {})
      @patterns.sort! do |a, b|
        (a.cost || 0) <=> (b.cost || 0)
      end
      self
    end

    ##
    # Executes this query on the given `queryable` graph or repository.
    #
    # @param  [RDF::Queryable] queryable
    #   the graph or repository to query
    # @param  [Hash{Symbol => Object}] options
    #   any additional keyword options
    # @return [RDF::Query::Solutions]
    #   the resulting solution sequence
    # @see    http://www.holygoat.co.uk/blog/entry/2005-10-25-1
    def execute(queryable, options = {})
      options = options.dup

      # just so we can call #keys below without worrying
      options[:bindings] ||= {}

      @solutions = Solutions.new
      # A quick empty solution simplifies the logic below; no special case for
      # the first pattern
      @solutions << RDF::Query::Solution.new({})

      @patterns.each do |pattern|
        
        old_solutions, @solutions = @solutions, Solutions.new

        options[:bindings].keys.each do |variable|
          if pattern.variables.include?(variable)
            unbound_solutions, old_solutions = old_solutions, Solutions.new
            options[:bindings][variable].each do |binding|
              unbound_solutions.each do |solution|
                old_solutions << solution.merge(variable => binding)
              end
            end
            options[:bindings].delete(variable)
          end
        end

        old_solutions.each do |solution|
          pattern.execute(queryable, solution) do |statement|
            @solutions << solution.merge(pattern.solution(statement))
          end
        end

        # It's important to abort failed queries quickly because later patterns
        # that can have constraints are often broad without them.
        # We have no solutions at all:
        return @solutions if @solutions.empty?
        # We have no solutions for variables we should have solutions for:
        if !pattern.optional? && pattern.variables.keys.any? { |variable| !@solutions.variable_names.include?(variable) }
          return Solutions.new
        end
      end
      @solutions
    end

    ##
    # Returns `true` if this query did not match when last executed.
    #
    # When the solution sequence is empty, this method can be used to
    # determine whether the query failed to match or not.
    #
    # @return [Boolean]
    # @see    #matched?
    def failed?
      @solutions.empty?
    end

    ##
    # Returns `true` if this query matched when last executed.
    #
    # When the solution sequence is empty, this method can be used to
    # determine whether the query matched successfully or not.
    #
    # @return [Boolean]
    # @see    #failed?
    def matched?
      !@failed
    end

    ##
    # Enumerates over each matching query solution.
    #
    # @yield  [solution]
    # @yieldparam [RDF::Query::Solution] solution
    # @return [Enumerator]
    def each_solution(&block)
      @solutions.each(&block)
    end
    alias_method :each, :each_solution

  protected

    ##
    # @private
    def compile_hash_patterns(hash_patterns)
      patterns = []
      hash_patterns.each do |s, pos|
        raise ArgumentError, "invalid hash pattern: #{hash_patterns.inspect}" unless pos.is_a?(Hash)
        pos.each do |p, os|
          case os
            when Hash
              patterns += os.keys.map { |o| [s, p, o] }
              patterns += compile_hash_patterns(os)
            when Array
              patterns += os.map { |o| [s, p, o] }
            else
              patterns << [s, p, os]
          end
        end
      end
      patterns.map { |pattern| Pattern.from(pattern) }
    end
  end # Query
end # RDF
