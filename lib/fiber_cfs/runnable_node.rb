# frozen_string_literal: true

module FiberCFS
  class RunnableNode < RedBlackTree::Node
    def <=> other
      if self.data.ready == other.data.ready
        self.data.vruns <=> other.data.vruns
      elsif self.data.ready
        -1
      elsif other.data.ready
        1
      end
    end
  end
end
