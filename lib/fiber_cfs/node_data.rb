# frozen_string_literal: true

module FiberCFS
  class NodeData < Data.define :fiber, :vruns, :ready, :timeout_time, :monitor
    class Error < StandardError; end

    def initialize fiber:, vruns:, ready: false, timeout_time: nil, monitor: nil
      super
    end
  end
end
