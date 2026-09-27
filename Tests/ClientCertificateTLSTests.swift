import Foundation
import Security
import XCTest
@testable import Cobble

@MainActor final class ClientCertificateTLSTests: XCTestCase {
    private final class Delegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        let keychain: SecKeychain
        let selectCertificate: Bool
        private(set) var authorities: [Data] = []

        init(keychain: SecKeychain, selectCertificate: Bool) {
            self.keychain = keychain
            self.selectCertificate = selectCertificate
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable
                            (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            switch challenge.protectionSpace.authenticationMethod {
            case NSURLAuthenticationMethodServerTrust:
                completionHandler(.useCredential,
                    challenge.protectionSpace.serverTrust.map(URLCredential.init(trust:)))
            case NSURLAuthenticationMethodClientCertificate:
                authorities = challenge.protectionSpace.distinguishedNames ?? []
                guard selectCertificate else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                Task { @MainActor in
                    let matches = WebKitPage.clientCertificateIdentities(
                        acceptedIssuers: self.authorities, searchList: [self.keychain])
                    guard let selected = matches.identities.first else {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                        return
                    }
                    completionHandler(.useCredential, URLCredential(identity: selected.identity,
                        certificates: selected.certificates, persistence: .none))
                }
            default:
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    func testURLSessionChallengeAuthenticatesSelectedChainAndCancellationSendsNoCertificate() async throws {
        let openssl = "/opt/homebrew/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: openssl) else {
            throw XCTSkip("OpenSSL fixture tool is unavailable")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CobbleMutualTLS-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeCertificates(openssl: openssl, directory: directory)

        let password = "cobble-fixture"
        let keychainURL = directory.appendingPathComponent("fixture.keychain")
        var keychain: SecKeychain?
        let createStatus = keychainURL.path.withCString { path in
            password.withCString { bytes in
                SecKeychainCreate(path, UInt32(password.utf8.count), bytes,
                                  false, nil, &keychain)
            }
        }
        XCTAssertEqual(createStatus, errSecSuccess)
        let isolatedKeychain = try XCTUnwrap(keychain)
        defer { SecKeychainDelete(isolatedKeychain) }
        let p12 = try Data(contentsOf: directory.appendingPathComponent("client.p12"))
        let options = [kSecImportExportPassphrase as String: password,
                       kSecImportExportKeychain as String: isolatedKeychain] as CFDictionary
        var imported: CFArray?
        XCTAssertEqual(SecPKCS12Import(p12 as CFData, options, &imported), errSecSuccess)

        var importedCertificate: CFArray?
        let unrelatedPEM = try Data(contentsOf: directory.appendingPathComponent("unrelated.crt"))
        XCTAssertEqual(SecItemImport(unrelatedPEM as CFData,
            nil, nil, nil, [], nil, isolatedKeychain, &importedCertificate), errSecSuccess)
        let remaining = try certificates(in: isolatedKeychain)
        let intermediate = try XCTUnwrap(remaining.first {
            SecCertificateCopySubjectSummary($0) as String? == "Cobble TLS Intermediate"
        })
        let intermediateName = try XCTUnwrap(
            SecCertificateCopyNormalizedSubjectSequence(intermediate) as Data?)
        let partial = WebKitPage.clientCertificateIdentities(
            acceptedIssuers: [intermediateName], searchList: [isolatedKeychain])
        XCTAssertEqual(partial.identities.count, 1)
        XCTAssertEqual(partial.identities.first?.certificates.count, 2)
        XCTAssertEqual(partial.identities.first?.choice.serialNumber, "950497DC0E4F0C6D")

        let success = try await request(directory: directory, keychain: isolatedKeychain,
                                        selectCertificate: true)
        XCTAssertEqual(success.data, Data("mutual TLS ok".utf8))
        // URLSession does not expose the OpenSSL server's advertised CA name on
        // this stack. An empty list means the server accepts any issuer.
        XCTAssertTrue(success.authorities.isEmpty)

        do {
            _ = try await request(directory: directory, keychain: isolatedKeychain,
                                  selectCertificate: false)
            XCTFail("Cancellation unexpectedly authenticated")
        } catch { }
    }

    private func request(directory: URL, keychain: SecKeychain,
                         selectCertificate: Bool) async throws -> (data: Data, authorities: [Data]) {
        let portFile = directory.appendingPathComponent("port-\(UUID())")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", Self.serverScript, directory.path, portFile.path]
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: portFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try Int(String(contentsOf: portFile, encoding: .utf8))
            .flatMap { $0 } ?? { throw CocoaError(.fileReadCorruptFile) }()
        let delegate = Delegate(keychain: keychain, selectCertificate: selectCertificate)
        let session = URLSession(configuration: .ephemeral, delegate: delegate,
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: URL(string: "https://127.0.0.1:\(port)/")!)
        return (data, delegate.authorities)
    }

    private func makeCertificates(openssl: String, directory: URL) throws {
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.currentDirectoryURL = directory
            process.executableURL = URL(fileURLWithPath: openssl)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        try "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n"
            .write(to: directory.appendingPathComponent("ca.ext"), atomically: true, encoding: .utf8)
        try "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n"
            .write(to: directory.appendingPathComponent("client.ext"), atomically: true, encoding: .utf8)
        try "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n"
            .write(to: directory.appendingPathComponent("server.ext"), atomically: true, encoding: .utf8)
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=Cobble TLS Root",
             "-keyout", "root.key", "-out", "root.crt", "-days", "1", "-sha256"])
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=Unrelated Root",
             "-keyout", "unrelated.key", "-out", "unrelated.crt", "-days", "1", "-sha256"])
        try run(["req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=Cobble TLS Intermediate",
             "-keyout", "intermediate.key", "-out", "intermediate.csr"])
        try run(["x509", "-req", "-in", "intermediate.csr", "-CA", "root.crt", "-CAkey", "root.key",
             "-CAcreateserial", "-out", "intermediate.crt", "-days", "1", "-sha256",
             "-extfile", "ca.ext"])
        try run(["req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=Cobble TLS Client",
             "-keyout", "client.key", "-out", "client.csr"])
        try run(["x509", "-req", "-in", "client.csr", "-CA", "intermediate.crt", "-CAkey", "intermediate.key",
             "-CAcreateserial", "-set_serial", "0x950497DC0E4F0C6D",
             "-out", "client.crt", "-days", "1", "-sha256", "-extfile", "client.ext"])
        try run(["req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1",
             "-keyout", "server.key", "-out", "server.csr"])
        try run(["x509", "-req", "-in", "server.csr", "-CA", "root.crt", "-CAkey", "root.key",
             "-CAcreateserial", "-out", "server.crt", "-days", "1", "-sha256",
             "-extfile", "server.ext"])
        try run(["pkcs12", "-export", "-inkey", "client.key", "-in", "client.crt",
             "-certfile", "intermediate.crt", "-out", "client.p12",
             "-passout", "pass:cobble-fixture"])
    }

    private func certificates(in keychain: SecKeychain) throws -> [SecCertificate] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassCertificate,
            kSecMatchSearchList: [keychain], kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll] as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess)
        return (result as? [SecCertificate]) ?? []
    }

    private static let serverScript = #"""
import socket, ssl, sys
directory, port_file = sys.argv[1:]
listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen(1)
open(port_file, 'w').write(str(listener.getsockname()[1]))
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.maximum_version = ssl.TLSVersion.TLSv1_2
context.load_cert_chain(directory + '/server.crt', directory + '/server.key')
context.load_verify_locations(directory + '/root.crt')
context.verify_mode = ssl.CERT_REQUIRED
try:
    connection = context.wrap_socket(listener.accept()[0], server_side=True)
    connection.recv(8192)
    body = b'mutual TLS ok'
    connection.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(body)).encode() + b'\r\nConnection: close\r\n\r\n' + body)
    connection.close()
except ssl.SSLError:
    pass
listener.close()
"""#
}
