# frozen_string_literal: true

module Hanikamu
  module RateLimit
    module UI
      # Presenter helpers for displaying registry configuration in limit cards.
      module ConfigHelpers
        def config
          @config ||= data.fetch("config", nil)
        end

        def config?
          !config.nil?
        end

        def adaptive?
          config&.dig("adaptive") == true
        end

        def config_items
          return [] unless config?

          items = base_config_items
          items.concat(adaptive_config_items) if adaptive?
          items
        end

        private

        def base_config_items
          [
            config_item("rate", config["rate"]),
            config_item("interval", config["interval"], suffix: "s"),
            config_item("check_interval", config["check_interval"], suffix: "s"),
            config_item("max_wait_time", config["max_wait_time"], suffix: "s"),
            { label: "metrics", value: config["metrics"] ? "on" : "off" }
          ]
        end

        def adaptive_config_items
          adaptive_tuning_items + adaptive_feedback_items + adaptive_runtime_items
        end

        def adaptive_tuning_items
          adaptive_rate_items + adaptive_timing_items
        end

        def adaptive_rate_items
          [
            config_item("initial_rate", config["initial_rate"]),
            config_item("min_rate", config["min_rate"]),
            config_item("max_rate", config["max_rate"], "none")
          ]
        end

        def adaptive_timing_items
          []
        end

        def adaptive_feedback_items
          [
            config_item("error_classes", Array(config["error_classes"]).join(", "), "none"),
            { label: "header_parser", value: config["has_header_parser"] ? "yes" : "no" },
            { label: "response_parser", value: config["has_response_parser"] ? "yes" : "no" }
          ]
        end

        def adaptive_runtime_items
          items = [
            { label: "current_rate", value: config["current_rate"]&.to_s || "—" },
            { label: "consecutive_successes", value: config["consecutive_successes"]&.to_s || "0" }
          ]
          append_ceiling_items(items)
          items << probe_status_item
          items
        end

        def append_ceiling_items(items)
          ceiling = config["error_ceiling"]
          return unless ceiling

          items << config_item("ceiling", ceiling)
          items << config_item("confidence", config["ceiling_confidence"], "0")
          items << config_item("ceiling_hits", config["ceiling_hits"], "0")
        end

        def probe_status_item
          remaining = config["cooldown_remaining"]
          cooldown = config["effective_cooldown"]
          value = if cooldown.nil?
                    "no ceiling"
                  elsif remaining.nil? || remaining <= 0
                    "ready"
                  else
                    "#{remaining.round}s / #{cooldown}s"
                  end
          { label: "probe", value: value }
        end

        def config_item(label, value, fallback = nil, suffix: nil)
          display = if value.nil?
                      fallback || "—"
                    elsif suffix
                      "#{value}#{suffix}"
                    else
                      value.to_s
                    end
          { label: label, value: display }
        end
      end
    end
  end
end
