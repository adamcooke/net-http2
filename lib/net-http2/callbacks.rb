module NetHttp2
  module Callbacks

    def on(event, &block)
      raise ArgumentError, 'on event must provide a block' unless block_given?

      @events ||= {}
      @events[event] ||= []
      @events[event] << block
    end

    def emit(event, arg)
      return unless @events && @events[event]
      @events[event].each { |b| b.call(arg) }
    end

  end
end
