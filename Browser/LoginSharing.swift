import Foundation

extension AppModel {
    /// ponytail: switch-time snapshots only; consider live renewal after this path is qualified.
    func shareLogin(from sourceID: BrowsingContextID, to destinationID: BrowsingContextID,
                    url: URL, exportTimeout: Duration = .seconds(10),
                    confirmReplacement: () -> Bool = { false },
                    isCurrent: () -> Bool) async -> String? {
        guard preferences.experimentalLoginSharing, !sourceID.isPrivate, !destinationID.isPrivate,
              sourceID.profileID == destinationID.profileID, sourceID.engineID != destinationID.engineID,
              !isDeletingProfile(sourceID.profileID), isCurrent() else { return nil }
        loginSharingMessage = nil
        var failure = String(localized: "Login sharing is busy or the profile is unavailable. Try switching engines again.")
        let ids: Set<BrowsingContextID> = [sourceID, destinationID]
        guard let profile = profiles.first(where: { $0.id == sourceID.profileID }),
              suspendedContexts.isDisjoint(with: ids) else {
            loginSharingMessage = failure
            return failure
        }
        failure = String(localized: "This build does not support login sharing between these engines. Use a compatible experimental Full build.")
        guard engines.engine(sourceID.engineID)?.capabilities.supportsCookieTransfer == true,
              engines.engine(destinationID.engineID)?.capabilities.supportsCookieTransfer == true else {
            loginSharingMessage = failure
            return failure
        }
        // Reuse the website-data fence: deletion and another transfer must not interleave.
        suspendedContexts.formUnion(ids)
        defer { suspendedContexts.subtract(ids) }
        do {
            failure = String(localized: "Login sharing requires an HTTPS address using the standard port.")
            _ = try EngineCookie.host(for: url)
            // ponytail: query markers catch clear OAuth handoffs, not every provider flow.
            if Self.isLoginHandoff(url) {
                loginSharingMessage = String(localized: "Login sharing was skipped during sign-in. Destination cookies were left unchanged.")
                return nil
            }
            failure = String(localized: "Login cookies could not be read safely from the source engine. You may need to sign in again.")
            let source = try engines.context(engineID: sourceID.engineID, profile: profile, siteSettings: siteSettings)
            let destination = try engines.context(engineID: destinationID.engineID, profile: profile, siteSettings: siteSettings)
            guard source.capabilities.supportsCookieTransfer, destination.capabilities.supportsCookieTransfer else {
                failure = String(localized: "This build does not support login sharing between these engines. Use a compatible experimental Full build.")
                throw EngineError.unsupported("cross-engine login sharing")
            }
            // Export and validate every scope before touching the destination.
            let scopes = try Self.loginSharingURLs(for: url)
            var omittedPartitions = false
            var snapshots: [(URL, [EngineCookie])] = []
            var seen: [[String]: EngineCookie] = [:]
            for scope in scopes {
                failure = String(localized: "Login cookies could not be read safely from the source engine. You may need to sign in again.")
                let snapshot = try await CookieExportRace.run(source: source, url: scope, timeout: exportTimeout)
                guard preferences.experimentalLoginSharing, isCurrent(), !Task.isCancelled else { return nil }
                failure = String(localized: "Some source cookies could not be safely shared. No cookies were copied. Sign in again in this engine.")
                // Known partitions stay isolated. Unknown/invalid omissions still abort.
                guard snapshot.partitioned >= 0, snapshot.skipped == snapshot.partitioned else {
                    throw EngineError.unsupported("these login cookies")
                }
                omittedPartitions = omittedPartitions || snapshot.partitioned > 0
                for cookie in snapshot.cookies {
                    try cookie.validate(for: scope)
                    let key = [cookie.name, cookie.domain, cookie.path]
                    if let previous = seen[key], previous != cookie {
                        failure = String(localized: "Source login cookies changed during transfer. No cookies were copied. Try switching engines again.")
                        throw EngineError.notReady("cookie snapshot changed")
                    }
                    seen[key] = cookie
                }
                snapshots.append((scope, snapshot.cookies))
            }
            if omittedPartitions && seen.isEmpty {
                failure = String(localized: "Only partitioned source cookies were found. Destination cookies were left unchanged.")
                throw EngineError.unsupported("partitioned-only login")
            }
            for (scope, cookies) in snapshots {
                let host = try EngineCookie.host(for: scope)
                guard seen.values.filter({ $0.matches(host: host) }).allSatisfy(cookies.contains) else {
                    failure = String(localized: "Source login cookies changed during transfer. No cookies were copied. Try switching engines again.")
                    throw EngineError.notReady("cookie snapshot changed")
                }
            }
            if seen.isEmpty {
                loginSharingMessage = String(localized: "No transferable source cookies were found. Destination cookies were left unchanged.")
                return nil
            }
            var replacementNeeded = false
            var destinationHasState = false
            var destinationSnapshots: [CookieTransferSnapshot] = []
            for (scope, cookies) in snapshots {
                failure = String(localized: "Destination cookies could not be read safely. Destination cookies were left unchanged.")
                let existing = try await CookieExportRace.run(source: destination, url: scope, timeout: exportTimeout)
                guard preferences.experimentalLoginSharing, isCurrent(), !Task.isCancelled else { return nil }
                failure = String(localized: "Some destination cookies cannot be safely replaced. Destination cookies were left unchanged.")
                guard existing.partitioned >= 0, existing.skipped == existing.partitioned else {
                    throw EngineError.unsupported("destination cookie metadata")
                }
                for cookie in existing.cookies { try cookie.validate(for: scope) }
                destinationHasState = destinationHasState || !existing.cookies.isEmpty || existing.partitioned > 0
                if !Self.sameCookies(existing.cookies, cookies) {
                    replacementNeeded = true
                }
                destinationSnapshots.append(existing)
            }
            guard preferences.experimentalLoginSharing, isCurrent(), !Task.isCancelled else { return nil }
            if !replacementNeeded {
                loginSharingMessage = String(localized: "Destination cookies already match the source. No cookies were copied.")
                return nil
            }
            if destinationHasState && !confirmReplacement() {
                guard preferences.experimentalLoginSharing, isCurrent(), !Task.isCancelled else { return nil }
                loginSharingMessage = String(localized: "Existing destination cookies were preserved. Sign in again if needed.")
                return nil
            }
            guard preferences.experimentalLoginSharing, isCurrent(), !Task.isCancelled else { return nil }
            for ((scope, _), previous) in zip(snapshots, destinationSnapshots) {
                failure = String(localized: "Destination cookies changed during transfer. Destination cookies were left unchanged.")
                let current = try await CookieExportRace.run(source: destination, url: scope, timeout: exportTimeout)
                guard preferences.experimentalLoginSharing, isCurrent(), !Task.isCancelled else { return nil }
                guard current.skipped == previous.skipped, current.partitioned == previous.partitioned,
                      Self.sameCookies(current.cookies, previous.cookies) else {
                    throw EngineError.notReady("destination cookie snapshot changed")
                }
            }
            for (scope, cookies) in snapshots {
                guard preferences.experimentalLoginSharing, isCurrent(), !Task.isCancelled else { return nil }
                failure = String(localized: "The destination engine could not accept or verify all login cookies. Sign in again in this engine.")
                let rejected = try await destination.replaceCookies(cookies, for: scope)
                guard preferences.experimentalLoginSharing, isCurrent(), !Task.isCancelled else { return nil }
                guard rejected == 0 else { throw EngineError.unsupported("these login cookies") }
            }
            loginSharingMessage = omittedPartitions
                ? String(localized: "Unpartitioned login cookies were shared; partitioned cookies were left untouched. The website may still require sign-in.")
                : String(localized: "Login cookies were shared. The website may still require sign-in.")
            return nil
        } catch {
            guard preferences.experimentalLoginSharing, isCurrent(), !Task.isCancelled else { return nil }
            if error is CookieTransferError {
                failure = String(localized: "This WebKit version cannot expose cookie partition information safely. Login sharing was stopped.")
            }
            // Native errors may contain cookie values or URLs; publish only bounded copy.
            loginSharingMessage = failure
            return failure
        }
    }

    /// Explicit Google auth group; no cross-provider discovery or domain widening.
    static func loginSharingURLs(for url: URL) throws -> [URL] {
        let host = try EngineCookie.host(for: url)
        guard host == "google.com" || host.hasSuffix(".google.com") else { return [url] }
        let hosts = ["google.com", "accounts.google.com", "www.google.com", host]
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }.map { URL(string: "https://" + $0 + "/")! }
    }

    static func isLoginHandoff(_ url: URL) -> Bool {
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        return names.contains("code_challenge") || names.contains("id_token")
            || names.isSuperset(of: ["state", "code"])
            || names.isSuperset(of: ["client_id", "response_type"])
    }

    private static func sameCookies(_ lhs: [EngineCookie], _ rhs: [EngineCookie]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var remaining = rhs
        for cookie in lhs {
            guard let index = remaining.firstIndex(of: cookie) else { return false }
            remaining.remove(at: index)
        }
        return true
    }

}

@MainActor private final class CookieExportRace {
    private struct TimedOut: Error {}
    private var continuation: CheckedContinuation<CookieTransferSnapshot, Error>?
    private var timeoutTask: Task<Void, Never>?

    static func run(source: any EngineContext, url: URL, timeout: Duration) async throws -> CookieTransferSnapshot {
        let operation = Task { try await source.exportCookies(for: url) }
        return try await withCheckedThrowingContinuation { continuation in
            CookieExportRace(continuation: continuation).start(operation: operation, timeout: timeout)
        }
    }

    private init(continuation: CheckedContinuation<CookieTransferSnapshot, Error>) {
        self.continuation = continuation
    }

    private func start(operation: Task<CookieTransferSnapshot, Error>, timeout: Duration) {
        Task {
            do { finish(.success(try await operation.value)) }
            catch { finish(.failure(error)) }
        }
        timeoutTask = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            operation.cancel()
            finish(.failure(TimedOut()))
        }
    }

    private func finish(_ result: Result<CookieTransferSnapshot, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        continuation.resume(with: result)
    }
}
