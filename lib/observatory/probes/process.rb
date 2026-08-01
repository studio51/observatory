# frozen_string_literal: true

module Observatory
  module Probes

    # Reads this process's own memory and garbage-collection state.
    #
    # ## Why memory is here at all
    #
    # `bin/dev`'s watchdog recycles a Puma worker whose RSS passes 2 GB. When
    # that happens, the useful question is not "was it over the limit" — the
    # watchdog already answered that — but "what was it doing on the way up". A
    # worker whose RSS climbs steadily while its allocation rate is flat is
    # leaking; one whose RSS climbs alongside a route's allocation count is
    # serving that route. Sampling both, per process, makes them distinguishable.
    #
    # ## RSS on macOS
    #
    # Production is a macOS box, where `/proc` does not exist. `ps` is the
    # portable answer but forking a process every fifteen seconds to ask about
    # memory would be its own small problem, so the reading is taken from
    # `GC.stat` where possible and falls back to one cheap `ps` call.
    #
    module Process
      KILOBYTE  = 1_024
      PAGE_SIZE = 4_096   # /proc/self/statm reports pages; 4 KiB on every supported platform

      class << self

        # A reading of this process's memory and GC state.
        #
        # @return [Hash{Symbol => Object}]
        #
        def sample
          Safely.call("probes.process.sample", fallback: {}) do
            stat = GC.stat

            {
              rss_bytes:           resident_bytes,
              cpu_seconds:         Clock.process_cpu.round(3),
              allocated_objects:   stat[:total_allocated_objects],
              freed_objects:       stat[:total_freed_objects],
              gc_count:            stat[:count],
              major_gc_count:      stat[:major_gc_count],
              minor_gc_count:      stat[:minor_gc_count],
              gc_total_time_ms:    (GC.respond_to?(:total_time) ? (GC.total_time / 1_000_000.0).round(3) : nil),
              heap_live_slots:     stat[:heap_live_slots],
              heap_available_slots: stat[:heap_available_slots],
              heap_free_slots:     stat[:heap_free_slots],
              old_objects:         stat[:old_objects],
              malloc_increase_bytes: stat[:malloc_increase_bytes],
              remembered_wb_unprotected_objects: stat[:remembered_wb_unprotected_objects],
              threads:             Thread.list.count,
            }
          end
        end

        # This process's resident set size.
        #
        # @return [Integer, nil] bytes, or nil when it cannot be read.
        #
        def resident_bytes
          from_proc || from_ps
        end

        # Forget the memoised platform detection. Test-suite hygiene only.
        #
        # @return [void]
        #
        def reset!
          @proc_available = nil

          nil
        end

      private

        # Linux: read `/proc/self/statm`, which is a file read and nothing else.
        #
        # The second field is the resident set in pages. `getconf PAGESIZE` is
        # 4 KiB on every platform this runs on, and reading it per sample to
        # confirm that would cost more than the reading is worth.
        #
        # @return [Integer, nil] bytes.
        #
        def from_proc
          @proc_available = File.readable?("/proc/self/statm") if @proc_available.nil?
          return nil unless @proc_available

          File.read("/proc/self/statm").split[1].to_i * PAGE_SIZE
        rescue StandardError
          nil
        end

        # macOS and everything else: one `ps` call.
        #
        # Runs on the sampler thread every fifteen seconds, never on a request
        # path. The output is parsed strictly — anything unexpected returns nil
        # rather than a guess.
        #
        # @return [Integer, nil] bytes.
        #
        def from_ps
          output = IO.popen([ "ps", "-o", "rss=", "-p", ::Process.pid.to_s ], err: File::NULL, &:read)
          kilobytes = output.to_s.strip[/\A\d+\z/]
          return nil if kilobytes.nil?

          kilobytes.to_i * KILOBYTE
        rescue Errno::ENOENT, Errno::EACCES, IOError
          nil
        end
      end
    end
  end
end
