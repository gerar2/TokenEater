import Foundation

/// Builds the `URLSession` every outbound request goes through, honouring the
/// user's SOCKS proxy setting. Shared by `APIClient` and `OAuthTokenRefresher`
/// so an account that is proxied for the usage calls is proxied for the OAuth
/// refresh grant too.
enum URLSessionFactory {
    /// Returns `URLSession.shared` when no valid proxy is configured. A
    /// syntactically invalid proxy target is rejected here so it never reaches
    /// `connectionProxyDictionary`.
    static func make(proxyConfig: ProxyConfig?) -> URLSession {
        guard let proxy = proxyConfig, proxy.isValidForUse else { return .shared }
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: true,
            kCFNetworkProxiesSOCKSProxy as String: proxy.host,
            kCFNetworkProxiesSOCKSPort as String: proxy.port,
        ]
        return URLSession(configuration: configuration)
    }
}
