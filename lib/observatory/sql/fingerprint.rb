# frozen_string_literal: true

module Observatory
  module Sql

    # Normalises a SQL statement into a fingerprint so that structurally
    # equivalent queries group together.
    #
    #   SELECT * FROM achievements WHERE id = 123
    #   SELECT * FROM achievements WHERE id = 456
    #
    # both fingerprint to:
    #
    #   SELECT * FROM achievements WHERE id = ?
    #
    # This matters more here than in a typical profiler. The failure mode
    # Observatory exists to catch is one query shape executed tens of thousands
    # of times with a different id each time — which the ActiveRecord query cache
    # then serves without MySQL ever seeing it. Grouped by fingerprint that is a
    # single, obvious line item; ungrouped it is 41,722 unique strings.
    #
    # Redaction is a side effect of normalisation, not a separate pass: literals
    # are replaced *before* anything is stored, so a bind value cannot reach the
    # database even by accident. {redact} is the same transformation exposed for
    # representative SQL.
    #
    # ## Cost
    #
    # This runs once per query, including the 86,000 in the pathological case, so
    # it is three passes of compiled regex over a short string and nothing else —
    # no parsing, no allocation beyond the result. See
    # `test/performance/fingerprint_benchmark_test.rb` for the measured cost, and
    # `Configuration#max_fingerprinted_queries` for the ceiling that stops even
    # this from mattering on a pathological request.
    #
    module Fingerprint

      # Literals to replace with a placeholder, in one alternation so the common
      # case is a single pass.
      # Order matters: quoted strings are matched before numbers so that a digit
      # inside a string literal is not replaced on its own.
      #
      LITERALS = /
        '(?:[^'\\]|\\.|'')*'          # single-quoted string, MySQL backslash- and doubled-quote escapes
        | "(?:[^"\\]|\\.|"")*"        # double-quoted string (MySQL without ANSI_QUOTES)
        | \bX'[0-9A-Fa-f]*'           # hex literal
        | \b0x[0-9A-Fa-f]+\b          # hex number
        | \b\d+\.\d+([eE][+-]?\d+)?\b # float
        | \b\d+\b                     # integer
      /x

      COLLAPSE_LISTS = /\((?:\s*\?\s*,)+\s*\?\s*\)/     # ( ?, ?, ? ) -> (?)

      # Runs of two or more whitespace characters, plus any single whitespace
      # character that is not already a plain space.
      #
      # Deliberately *not* `/\s+/`. That matches every single space in the
      # statement, so `gsub!` rewrites the entire string even when there is
      # nothing to normalise — measured at 2.9 microseconds per query against
      # 0.3 for this version. On the 86,359-query request that difference alone
      # is a quarter of a second.
      #
      WHITESPACE  = /\s\s+|[^\S ]/
      PLACEHOLDER = "?".freeze
      LIST        = "(?)".freeze
      SPACE       = " ".freeze
      OPEN_PAREN  = "(".freeze
      MAX_LENGTH  = 4_000                               # fingerprints longer than this are truncated

      # Tables named in the statement, used to give a query group a model hint.
      #
      TABLE_HINT = /
        (?:FROM|JOIN|INTO|UPDATE)\s+
        [`"]?([A-Za-z_][A-Za-z0-9_$]*)[`"]?
      /xi

      class << self

        # Normalise a statement into its fingerprint.
        #
        # @param sql [String, nil] the raw statement as ActiveRecord issued it.
        #
        # @return [String] the normalised, value-free fingerprint; `""` for nil/blank input.
        #
        def call(sql)
          return "".freeze if sql.nil? || sql.empty?

          normalised = sql.gsub(LITERALS, PLACEHOLDER)
          normalised.gsub!(COLLAPSE_LISTS, LIST) if normalised.include?(OPEN_PAREN)
          normalised.gsub!(WHITESPACE, SPACE)
          normalised.strip!

          normalised.length > MAX_LENGTH ? normalised[0, MAX_LENGTH] : normalised
        end

        # Redact a statement for display, keeping its shape but none of its values.
        #
        # Identical to {call} but length-limited for storage as a group's
        # representative SQL.
        #
        # @param sql [String, nil] the raw statement.
        # @param limit [Integer] maximum characters to keep.
        #
        # @return [String] redacted SQL, truncated with an ellipsis when over `limit`.
        #
        def redact(sql, limit: Observatory.config.representative_sql_length)
          fingerprint = call(sql)

          return fingerprint if fingerprint.length <= limit

          "#{fingerprint[0, limit]}…"
        end

        # Best-effort table name for a statement, used as a model hint in the UI.
        #
        # Derived from the statement's first FROM/JOIN/INTO/UPDATE clause. It is a
        # hint, not a guarantee — a multi-table statement reports only the first —
        # so nothing in the analysis engine reasons from it.
        #
        # @param sql [String, nil] the raw or fingerprinted statement.
        #
        # @return [String, nil] the table name, or nil when none could be read.
        #
        def table_for(sql)
          return nil if sql.nil? || sql.empty?

          match = TABLE_HINT.match(sql)

          match && match[1]
        end

        # Classify a statement by the kind of work it represents.
        #
        # Schema and transaction statements are separated from application queries
        # because a request issuing 400 `SHOW FULL FIELDS` on a cold boot is a
        # completely different finding from one issuing 400 `SELECT`s in a loop.
        #
        # @param sql [String, nil] the raw statement.
        # @param name [String, nil] ActiveRecord's name for the query, e.g. "User Load".
        #
        # @return [Symbol] one of :schema, :transaction or :query.
        #
        def classify(sql, name)
          return :schema      if schema_name?(name)
          return :transaction if transaction_name?(name)

          leading = leading_keyword(sql)

          return :transaction if TRANSACTION_KEYWORDS.include?(leading)
          return :schema      if SCHEMA_KEYWORDS.include?(leading)

          :query
        end
      end

      # ActiveRecord query names that always denote schema introspection.
      #
      SCHEMA_NAMES = [ "SCHEMA".freeze ].freeze

      # ActiveRecord query names that always denote transaction management.
      #
      TRANSACTION_NAMES = [ "TRANSACTION".freeze ].freeze

      # Leading keywords that mark a statement as transaction management.
      #
      TRANSACTION_KEYWORDS = %w[BEGIN COMMIT ROLLBACK SAVEPOINT RELEASE].freeze

      # Leading keywords that mark a statement as schema introspection or DDL.
      #
      SCHEMA_KEYWORDS = %w[SHOW DESCRIBE DESC EXPLAIN SET CREATE ALTER DROP].freeze

      class << self

      private

        # @param name [String, nil] ActiveRecord's query name.
        #
        # @return [Boolean] whether the name marks a schema query.
        #
        def schema_name?(name)
          !name.nil? && SCHEMA_NAMES.include?(name)
        end

        # @param name [String, nil] ActiveRecord's query name.
        #
        # @return [Boolean] whether the name marks transaction management.
        #
        def transaction_name?(name)
          !name.nil? && TRANSACTION_NAMES.include?(name)
        end

        # The statement's first word, upcased, without allocating a split of the
        # whole string.
        #
        # @param sql [String, nil] the raw statement.
        #
        # @return [String] the leading keyword, or `""` when unreadable.
        #
        def leading_keyword(sql)
          return "".freeze if sql.nil? || sql.empty?

          stripped = sql.lstrip
          boundary = stripped.index(" ") || stripped.length

          stripped[0, boundary].upcase
        end
      end
    end
  end
end
