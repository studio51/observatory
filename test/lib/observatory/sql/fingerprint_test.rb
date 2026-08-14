# frozen_string_literal: true

require "test_helper"

module Observatory
  module Sql

    # Fingerprinting is the mechanism that turns 41,722 unique query strings into
    # one line item, so these tests care about two things above all: that
    # equivalent queries collapse together, and that no literal value survives.
    #
    class FingerprintTest < ActiveSupport::TestCase

      test "collapses queries that differ only by an integer literal" do
        first  = Fingerprint.call("SELECT * FROM achievements WHERE id = 123")
        second = Fingerprint.call("SELECT * FROM achievements WHERE id = 456")

        assert_equal first, second
        assert_equal "SELECT * FROM achievements WHERE id = ?", first
      end

      test "collapses queries that differ only by a string literal" do
        first  = Fingerprint.call("SELECT * FROM users WHERE username = 'tifo'")
        second = Fingerprint.call("SELECT * FROM users WHERE username = 'someone else'")

        assert_equal first, second
        assert_equal "SELECT * FROM users WHERE username = ?", first
      end

      test "collapses an IN list to a single placeholder regardless of length" do
        short = Fingerprint.call("SELECT * FROM games WHERE id IN (1, 2, 3)")
        long  = Fingerprint.call("SELECT * FROM games WHERE id IN (#{(1..500).to_a.join(", ")})")

        assert_equal short, long
        assert_equal "SELECT * FROM games WHERE id IN (?)", short
      end

      test "does not conflate genuinely different queries" do
        achievements = Fingerprint.call("SELECT * FROM achievements WHERE id = 1")
        trophies     = Fingerprint.call("SELECT * FROM trophies WHERE id = 1")

        assert_not_equal achievements, trophies
      end

      test "leaves no digits or quoted values in the fingerprint" do
        sql = "SELECT * FROM orders WHERE total = 19.99 AND ref = 'ABC-123' AND created_at > '2026-01-01'"

        fingerprint = Fingerprint.call(sql)

        assert_no_match(/\d/, fingerprint)
        assert_no_match(/'/, fingerprint)
      end

      test "survives escaped and doubled quotes without leaking their contents" do
        fingerprint = Fingerprint.call("SELECT * FROM users WHERE bio = 'it''s a secret' AND note = 'a\\'b'")

        assert_no_match(/secret/, fingerprint)
        assert_equal "SELECT * FROM users WHERE bio = ? AND note = ?", fingerprint
      end

      test "normalises whitespace so formatting differences group together" do
        formatted = Fingerprint.call("SELECT *\n  FROM users\n  WHERE id = 1")
        inline    = Fingerprint.call("SELECT * FROM users WHERE id = 2")

        assert_equal inline, formatted
      end

      test "returns an empty fingerprint for nil or blank input" do
        assert_equal "", Fingerprint.call(nil)
        assert_equal "", Fingerprint.call("")
      end

      test "truncates a pathologically long statement" do
        sql = "SELECT * FROM t WHERE id IN (#{(1..50_000).to_a.join(",")})"

        assert_operator Fingerprint.call(sql).length, :<=, Fingerprint::MAX_LENGTH
      end

      test "redact truncates to the configured display length with an ellipsis" do
        redacted = Fingerprint.redact("SELECT #{"column_name, " * 200} FROM users", limit: 50)

        assert_equal 51, redacted.length
        assert redacted.end_with?("…")
      end

      test "reads a table hint from the statement" do
        assert_equal "achievements", Fingerprint.table_for("SELECT * FROM achievements WHERE id = 1")
        assert_equal "users", Fingerprint.table_for("UPDATE `users` SET name = 'x'")
        assert_equal "trophies", Fingerprint.table_for("INSERT INTO trophies (id) VALUES (1)")
        assert_nil Fingerprint.table_for("BEGIN")
      end

      test "classifies transaction management separately from application queries" do
        assert_equal :transaction, Fingerprint.classify("BEGIN", nil)
        assert_equal :transaction, Fingerprint.classify("COMMIT", nil)
        assert_equal :transaction, Fingerprint.classify("SAVEPOINT active_record_1", nil)
        assert_equal :transaction, Fingerprint.classify("SELECT 1", "TRANSACTION")
      end

      test "classifies schema introspection separately from application queries" do
        assert_equal :schema, Fingerprint.classify("SHOW FULL FIELDS FROM `users`", nil)
        assert_equal :schema, Fingerprint.classify("SELECT 1", "SCHEMA")
        assert_equal :query, Fingerprint.classify("SELECT * FROM users", "User Load")
      end
    end
  end
end
