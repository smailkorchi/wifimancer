private extension FixtureClient {
    func invoke<Value: Sendable>(timeout: TimeInterval? = nil,
        _ call: (HelperProtocol, @escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value { try await request(timeout: timeout, call) }
}

@main
private struct RPCTests {
    @MainActor
    static func main() async throws {
        let client = FixtureClient()
        do {
            let _: Int = try await client.invoke { _, finish in finish(.success(1)) }
            preconditionFailure("Missing connection must throw")
        } catch { precondition(error.localizedDescription == "helper not connected") }
        let unavailable = FixtureConnection(proxy: nil)
        client.connection = unavailable
        do {
            let _: Int = try await client.invoke { _, finish in finish(.success(1)) }
            preconditionFailure("Unavailable proxy must throw")
        } catch { precondition(error.localizedDescription == "helper not connected") }
        let connection = FixtureConnection()
        client.connection = connection
        do {
            let _: Int = try await client.invoke { _, finish in
                connection.errorHandler?(HC.error("remote interrupted"))
                finish(.success(1))
            }
            preconditionFailure("XPC error must finish before its late reply")
        } catch { precondition(error.localizedDescription == "remote interrupted") }
        let first: Int = try await client.invoke { _, finish in
            finish(.success(7))
            connection.errorHandler?(HC.error("late error"))
            finish(.success(8))
        }
        precondition(first == 7)
        for _ in 0..<100 {
            let value: Int = try await client.invoke { _, finish in
                DispatchQueue.global().async { finish(.success(1)) }
                DispatchQueue.global().async { finish(.success(2)) }
            }
            precondition(value == 1 || value == 2)
        }
        do {
            let _: Int = try await client.invoke(timeout: 0.001) { _, finish in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { finish(.success(1)) }
            }
            preconditionFailure("Timeout must complete")
        } catch { precondition(error.localizedDescription == "timeout") }
        try await Task.sleep(nanoseconds: 10_000_000)
        print("RPC completion passed: missing connection/proxy, per-request remote error, late reply/error, 100 concurrent double replies, and watchdog")
    }
}
