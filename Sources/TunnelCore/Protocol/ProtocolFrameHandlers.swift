import NIOCore

public final class ProtocolFrameDecoder: ByteToMessageDecoder {
    public typealias InboundOut = ProtocolFrame

    public init() {}

    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws
        -> DecodingState
    {
        // Keep track of the initial reader index to reset if we need more data
        let startReaderIndex = buffer.readerIndex

        do {
            let frame = try ProtocolFrame.decode(from: &buffer)
            context.fireChannelRead(wrapInboundOut(frame))
            return .continue
        } catch let error as ProtocolError {
            switch error {
            case .insufficientData:
                // Reset reader index so next attempt reads from the start
                buffer.moveReaderIndex(to: startReaderIndex)
                return .needMoreData
            default:
                throw error
            }
        } catch {
            throw error
        }
    }

    public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool)
        throws -> DecodingState
    {
        return try decode(context: context, buffer: &buffer)
    }
}

public final class ProtocolFrameEncoder: MessageToByteEncoder {
    public typealias OutboundIn = ProtocolFrame

    public init() {}

    public func encode(data: ProtocolFrame, out: inout ByteBuffer) throws {
        data.encode(into: &out)
    }
}
