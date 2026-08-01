# frozen_string_literal: true

module Observatory

  # Formatting for the dashboard.
  #
  # ## One rule runs through all of it
  #
  # **Nil is "unknown", and unknown is never rendered as zero.** A backlog that
  # could not be measured, a queue wait the proxy does not send, a baseline that
  # does not exist yet — each of those is a real state, and showing it as `0`
  # would be a lie that changes what an operator concludes. Every formatter here
  # returns an em dash for nil, and the panels say why where it matters.
  #
  # The second rule: an estimate is labelled as an estimate. Allocation and GC
  # figures carry a marker wherever they appear, because CRuby's counters are
  # process-wide and this system does not pretend otherwise.
  #
  module DashboardHelper
    UNKNOWN = "—".freeze

    # A duration, scaled to something readable.
    #
    # @param milliseconds [Numeric, nil] the duration.
    #
    # @return [String]
    #
    def observatory_duration(milliseconds)
      return UNKNOWN if milliseconds.nil?

      value = milliseconds.to_f

      return "#{value.round(1)}ms" if value < 1_000
      return "#{(value / 1_000).round(2)}s" if value < 60_000

      "#{(value / 60_000).round(1)}m"
    end

    # A count with thousands separators.
    #
    # @param value [Numeric, nil] the number.
    #
    # @return [String]
    #
    def observatory_count(value)
      return UNKNOWN if value.nil?

      value.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end

    # A ratio as a percentage.
    #
    # @param ratio [Numeric, nil] 0.0-1.0.
    # @param places [Integer] decimal places.
    #
    # @return [String]
    #
    def observatory_percentage(ratio, places = 1)
      return UNKNOWN if ratio.nil?

      "#{(ratio.to_f * 100).round(places)}%"
    end

    # A byte count, scaled.
    #
    # @param bytes [Numeric, nil] the size.
    #
    # @return [String]
    #
    def observatory_bytes(bytes)
      return UNKNOWN if bytes.nil? || bytes.to_i.zero?

      number_to_human_size(bytes)
    end

    # A duration in seconds, in words.
    #
    # @param seconds [Numeric, nil] the duration.
    #
    # @return [String]
    #
    def observatory_seconds(seconds)
      return UNKNOWN if seconds.nil?
      return "not draining" if seconds.respond_to?(:infinite?) && seconds.infinite?
      return "#{seconds.round}s" if seconds < 120

      ActiveSupport::Duration.build(seconds.to_i).inspect
    end

    # The Tailwind text colour for a health state.
    #
    # @param state [Symbol] :ok, :warning or :critical.
    #
    # @return [String]
    #
    def observatory_state_class(state)
      case state
      when :critical then "text-red-400"
      when :warning  then "text-amber-400"
      when :ok       then "text-emerald-400"
      else                "text-gray-400"
      end
    end

    # The Tailwind classes for an incident's severity badge.
    #
    # @param severity [String, Symbol] :critical, :warning or :info.
    #
    # @return [String]
    #
    def observatory_severity_class(severity)
      case severity.to_s
      when "critical" then "bg-red-500/15 text-red-300 ring-red-500/30"
      when "warning"  then "bg-amber-500/15 text-amber-300 ring-amber-500/30"
      else                 "bg-sky-500/15 text-sky-300 ring-sky-500/30"
      end
    end

    # Classify a utilisation figure so a panel can colour itself.
    #
    # @param ratio [Numeric, nil] 0.0-1.0.
    # @param warning [Float] the ratio at which it becomes a warning.
    # @param critical [Float] the ratio at which it becomes critical.
    #
    # @return [Symbol] :ok, :warning, :critical or :unknown.
    #
    def observatory_state_for(ratio, warning: 0.75, critical: 0.95)
      return :unknown if ratio.nil?
      return :critical if ratio >= critical
      return :warning if ratio >= warning

      :ok
    end

    # A horizontal bar, computed in Ruby and drawn in HTML.
    #
    # The house style here is server-rendered charts — this is a div with a
    # width, not a charting library. It cannot fail to load, cannot shift the
    # layout, and works with JavaScript switched off.
    #
    # @param ratio [Numeric, nil] 0.0-1.0.
    # @param state [Symbol] the colour to draw it in.
    #
    # @return [String] HTML.
    #
    def observatory_bar(ratio, state: :ok)
      width = [ [ ratio.to_f, 0.0 ].max, 1.0 ].min * 100
      colour = { ok: "bg-emerald-500", warning: "bg-amber-500", critical: "bg-red-500",
                 unknown: "bg-gray-600", }.fetch(state, "bg-gray-600")

      tag.div(class: "h-1.5 w-full rounded-full bg-white/5 overflow-hidden") do
        tag.div("", class: "h-full rounded-full #{colour}", style: "width: #{width.round(2)}%")
      end
    end

    # A sparkline drawn as inline SVG from a series of values.
    #
    # Server-rendered for the same reasons as {observatory_bar}: the data is
    # already in Ruby, and a chart that needs a request to render is a chart that
    # is blank during the incident when the browser is busy.
    #
    # @param values [Array<Numeric>] the series.
    # @param width [Integer] the SVG width in user units.
    # @param height [Integer] the SVG height in user units.
    # @param colour [String] the stroke colour.
    #
    # @return [String] HTML, or an em dash when there is nothing to draw.
    #
    def observatory_sparkline(values, width: 240, height: 40, colour: "#34d399")
      series = Array(values).map(&:to_f)
      return UNKNOWN if series.size < 2

      peak = series.max
      peak = 1.0 if peak <= 0
      step = width.to_f / (series.size - 1)

      points = series.each_with_index.map do |value, index|
        "#{(index * step).round(2)},#{(height - ((value / peak) * (height - 2))).round(2)}"
      end.join(" ")

      tag.svg(viewBox: "0 0 #{width} #{height}", class: "w-full h-10", preserveAspectRatio: "none") do
        tag.polyline(nil, points:, fill: "none", stroke: colour, "stroke-width": 1.5,
                          "vector-effect": "non-scaling-stroke")
      end
    end

    # A marker for a measurement that cannot be exact.
    #
    # @return [String] HTML.
    #
    def observatory_estimated
      tag.span("est.", class: "text-[10px] uppercase tracking-wide text-gray-500 ml-1",
                       title: "Process-wide counter shared by concurrent threads — an estimate, not an " \
                              "attribution. CRuby has no per-thread allocation counter.")
    end
  end
end
