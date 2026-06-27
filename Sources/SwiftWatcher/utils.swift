import Foundation
import Hummingbird
import UUIDV7

struct BuildId: CustomStringConvertible, Equatable {
    let inner: UUIDV7
    var description: String { self.inner.uuidString }

    init() {
        self.inner = UUIDV7.now
    }

    init?(parse uuidString: String) {
        let parsedUuid = UUIDV7(uuidString: uuidString)
        switch parsedUuid {
            case .some(let uuid): self.inner = uuid

            // Failed to parse
            case .none: return nil
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        return if self.indices.contains(index) { self[index] } else { nil }
    }
}

extension UInt32 {
    func saturatingSub(_ rhs: UInt32) -> UInt32 {
        if self > rhs { self - rhs } else { 0 }
    }
}

extension String {
    func replacingPlaceholders(_ replacements: [String: String]) -> String {
        replacements.reduce(
            self,
            { acc, replacement in
                acc.replacingOccurrences(of: replacement.key, with: replacement.value)
            }
        )
    }
}

extension Result where Failure == Error {
    init(_ body: () throws -> Success) {
        do { self = .success(try body()) } catch { self = .failure(error) }
    }

    init(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

extension ResponseBody {
    func collect() async -> ByteBuffer? {
        final class ByteBufferBox { var buffer = ByteBuffer() }

        struct Collector: ResponseBodyWriter {
            let box: ByteBufferBox
            func write(_ buffer: ByteBuffer) async throws {
                self.box.buffer.writeImmutableBuffer(buffer)
            }
            consuming func finish(_ trailingHeaders: HTTPFields?) async throws {}
        }

        let box = ByteBufferBox()

        guard case .success = await Result({ try await self.write(Collector(box: box)) }) else {
            return nil
        }

        return box.buffer
    }
}
