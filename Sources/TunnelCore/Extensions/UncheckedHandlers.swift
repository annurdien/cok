import NIOCore

public final class UncheckedInboundHandler<H: ChannelInboundHandler>: ChannelInboundHandler,
    @unchecked Sendable
{
    public typealias InboundIn = H.InboundIn
    public typealias InboundOut = H.InboundOut

    private let handler: H

    public init(_ handler: H) {
        self.handler = handler
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        handler.handlerAdded(context: context)
    }
    public func handlerRemoved(context: ChannelHandlerContext) {
        handler.handlerRemoved(context: context)
    }

    public func channelRegistered(context: ChannelHandlerContext) {
        handler.channelRegistered(context: context)
    }
    public func channelUnregistered(context: ChannelHandlerContext) {
        handler.channelUnregistered(context: context)
    }
    public func channelActive(context: ChannelHandlerContext) {
        handler.channelActive(context: context)
    }
    public func channelInactive(context: ChannelHandlerContext) {
        handler.channelInactive(context: context)
    }
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        handler.channelRead(context: context, data: data)
    }
    public func channelReadComplete(context: ChannelHandlerContext) {
        handler.channelReadComplete(context: context)
    }
    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        handler.userInboundEventTriggered(context: context, event: event)
    }
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        handler.errorCaught(context: context, error: error)
    }
    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        handler.channelWritabilityChanged(context: context)
    }
}

public final class UncheckedOutboundHandler<H: ChannelOutboundHandler>: ChannelOutboundHandler,
    @unchecked Sendable
{
    public typealias OutboundIn = H.OutboundIn
    public typealias OutboundOut = H.OutboundOut

    private let handler: H

    public init(_ handler: H) {
        self.handler = handler
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        handler.handlerAdded(context: context)
    }
    public func handlerRemoved(context: ChannelHandlerContext) {
        handler.handlerRemoved(context: context)
    }

    public func register(context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        handler.register(context: context, promise: promise)
    }
    public func bind(
        context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?
    ) { handler.bind(context: context, to: address, promise: promise) }
    public func connect(
        context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?
    ) { handler.connect(context: context, to: address, promise: promise) }
    public func write(
        context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?
    ) { handler.write(context: context, data: data, promise: promise) }
    public func flush(context: ChannelHandlerContext) { handler.flush(context: context) }
    public func close(
        context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?
    ) { handler.close(context: context, mode: mode, promise: promise) }
    public func triggerUserOutboundEvent(
        context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?
    ) { handler.triggerUserOutboundEvent(context: context, event: event, promise: promise) }
}
