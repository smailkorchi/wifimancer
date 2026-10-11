import Foundation

private protocol HelperProtocol: AnyObject {}
private final class FixtureProxy: HelperProtocol {}
private final class FixtureConnection {
    var errorHandler: ((Error) -> Void)?
    var proxy: Any?
    init(proxy: Any? = FixtureProxy()) { self.proxy = proxy }
    func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any {
        errorHandler = handler
        return proxy as Any
    }
}
private enum HC {
    static func error(_ message: String) -> NSError {
        NSError(domain: "HelperClient", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
