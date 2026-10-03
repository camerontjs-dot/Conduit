import Foundation

/// Measures the local Foundation dispatch/return boundary of the supplied
/// request. A response callback is not provider acceptance or completion.
/// The request, response bytes and original transport error are unchanged.
@MainActor
public enum OpenCodeBoundaryTransport {
    public static func data(
        for request: URLRequest,
        using session: URLSession = .shared,
        onStart: () -> Void,
        onResponse: (Int?) -> Void,
        onFailure: () -> Void
    ) async throws -> (Data, URLResponse) {
        onStart()
        do {
            let result = try await session.data(for: request)
            onResponse((result.1 as? HTTPURLResponse)?.statusCode)
            return result
        } catch {
            onFailure()
            throw error
        }
    }
}
