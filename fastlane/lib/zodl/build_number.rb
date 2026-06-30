# frozen_string_literal: true

module Zodl
  # Validates a developer-supplied build number against the latest build already
  # on App Store Connect for the same app. Build numbers must strictly increase.
  module BuildNumber
    class Result
      attr_reader :error, :warning

      def initialize(error: nil, warning: nil)
        @error = error
        @warning = warning
      end

      def ok?
        @error.nil?
      end
    end

    module_function

    def validate(requested:, latest:)
      req = Integer(requested)
      return Result.new(error: "build must be >= 1, got #{req}") if req < 1

      top = latest.nil? ? 0 : Integer(latest)

      if req == top
        Result.new(error: "build #{req} already exists on App Store Connect")
      elsif req < top
        Result.new(error: "build #{req} is lower than the latest build #{top} on App Store Connect")
      elsif req > top + 1
        Result.new(warning: "build #{req} skips numbers (latest is #{top}) — possible typo")
      else
        Result.new
      end
    rescue ArgumentError, TypeError
      Result.new(error: "build must be an integer, got #{requested.inspect}")
    end
  end
end
