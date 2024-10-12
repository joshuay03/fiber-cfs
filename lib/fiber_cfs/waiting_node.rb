# frozen_string_literal: true

module FiberCFS
  class WaitingNode < RedBlackTree::Node
    def <=> other
      (self.data.timeout_time || Float::INFINITY) <=> (other.data.timeout_time || Float::INFINITY)
    end
  end
end
