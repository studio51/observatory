# frozen_string_literal: true

module Observatory
  module Pipeline

    # A fixed-capacity, priority-aware queue between collection and persistence.
    #
    # ## Why this cannot be a plain Queue
    #
    # Ruby's `Queue` is unbounded. Point it at a database that has become slow —
    # which, during an incident, is exactly what happens — and it grows until the
    # process dies. The monitoring system would then have converted a latency
    # problem into an out-of-memory kill. `SizedQueue` fixes the bound but blocks
    # the pusher, which is worse: the pusher is a request thread, and blocking it
    # means the monitoring system is now holding the very Puma capacity it exists
    # to protect.
    #
    # So this buffer is bounded **and** never blocks. When it is full it drops —
    # and what it drops is chosen, not arbitrary.
    #
    # ## What gets dropped first
    #
    # Events carry a priority. When the buffer is full:
    #
    # 1. a `:normal` event arriving at a full buffer is dropped immediately;
    # 2. a `:high` event (an anomaly) evicts the oldest `:normal` event if one
    #    exists, and is otherwise dropped;
    # 3. a `:critical` event (an exception, a 5xx, a failed health check, a
    #    saturation incident) evicts the oldest lower-priority event, and is only
    #    dropped if the entire buffer is already critical.
    #
    # The consequence is the one that matters during an incident: as pressure
    # rises, the data that survives is the data about the incident. Losing a
    # thousand routine 200s to keep six saturating requests is the correct trade,
    # and it is made automatically.
    #
    # Every drop increments a counter. Those counters are surfaced on the
    # dashboard, because a monitoring system silently discarding its input while
    # claiming to be healthy is its own failure mode.
    #
    class Buffer
      PRIORITIES = { normal: 0, high: 1, critical: 2 }.freeze

      # One buffered event, with the priority that decides its fate under pressure.
      #
      Entry = Struct.new(
        :priority,  # Integer: 0 normal, 1 high, 2 critical
        :payload,   # Hash: the serialised execution
      )

      attr_reader :capacity

      # @param capacity [Integer] events held before dropping begins.
      #
      # @return [Observatory::Pipeline::Buffer]
      #
      def initialize(capacity: Observatory.config.buffer_capacity)
        @capacity = capacity
        @entries  = []
        @mutex    = Mutex.new
        @signal   = ConditionVariable.new
        @dropped  = Hash.new(0)
        @accepted = 0
        @evicted  = 0
      end

      # Offer an event to the buffer.
      #
      # Never blocks and never raises. Returns whether the event was accepted, so
      # a caller can tell the difference between "stored" and "silently gone" —
      # though in practice only the counters read it.
      #
      # @param payload [Hash] the serialised execution.
      # @param priority [Symbol] :normal, :high or :critical.
      #
      # @return [Boolean] whether the event was accepted.
      #
      def push(payload, priority: :normal)
        level = PRIORITIES.fetch(priority, 0)

        @mutex.synchronize do
          if @entries.size >= @capacity && !make_room(level)
            @dropped[priority] += 1

            return false
          end

          @entries << Entry.new(level, payload)
          @accepted += 1
          @signal.signal

          true
        end
      end

      # Take up to `limit` events, oldest first.
      #
      # Waits up to `timeout` seconds for at least one event rather than spinning,
      # so an idle process costs nothing.
      #
      # @param limit [Integer] maximum events to return.
      # @param timeout [Float] seconds to wait when the buffer is empty.
      #
      # @return [Array<Hash>] the payloads, oldest first; empty when nothing arrived.
      #
      def pop_batch(limit: Observatory.config.batch_size, timeout: Observatory.config.flush_interval)
        @mutex.synchronize do
          @signal.wait(@mutex, timeout) if @entries.empty?

          @entries.shift(limit).map(&:payload)
        end
      end

      # How many events are waiting.
      #
      # @return [Integer]
      #
      def size
        @mutex.synchronize { @entries.size }
      end

      # Whether anything is waiting.
      #
      # @return [Boolean]
      #
      def empty?
        size.zero?
      end

      # Counters describing how the buffer has coped.
      #
      # `dropped` is the number the dashboard shows and the number that should be
      # zero. A non-zero value means Observatory is losing data and its own
      # numbers are incomplete — which is worth knowing before drawing
      # conclusions from them.
      #
      # @return [Hash{Symbol => Object}]
      #
      def stats
        @mutex.synchronize do
          {
            size:     @entries.size,
            capacity: @capacity,
            accepted: @accepted,
            evicted:  @evicted,
            dropped:  @dropped.values.sum,
            dropped_by_priority: @dropped.dup,
          }
        end
      end

      # Discard everything and reset the counters. Test-suite hygiene only.
      #
      # @return [void]
      #
      def clear!
        @mutex.synchronize do
          @entries.clear
          @dropped.clear
          @accepted = 0
          @evicted  = 0
        end

        nil
      end

    private

      # Evict the oldest event of a strictly lower priority, if one exists.
      #
      # Called with the mutex held, only when the buffer is full.
      #
      # @param level [Integer] the incoming event's priority.
      #
      # @return [Boolean] whether room was made.
      #
      def make_room(level)
        return false if level.zero?

        index = @entries.index { |entry| entry.priority < level }
        return false if index.nil?

        evicted = @entries.delete_at(index)
        @dropped[PRIORITIES.key(evicted.priority)] += 1
        @evicted += 1

        true
      end
    end
  end
end
