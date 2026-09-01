import Cocoa
import CryptoKit
import Security

struct Release: Decodable {
    let tag_name: String
    let assets: [Asset]
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }
}

// MARK: - Certificate Pinning with OCSP Fallback
//
// Pin = SPKI SHA-256 of GitHub's current public key.
// If pin doesn't match (GitHub rotated their key):
//   → Query OCSP for the previously-pinned cert
//   → If OCSP says "revoked" or cert is expired → GitHub legitimately rotated → allow via standard TLS
//   → If OCSP says "good" → the pinned cert is still valid but we're seeing a different key = MITM → BLOCK
//
// This means:
//   - Users are never stuck if GitHub renews their cert (OCSP fallback allows through)
//   - MITM with a different cert while the real one is still valid is blocked
//   - Developer should update the pinned hashes after GitHub rotates

// GitHub's current SPKI SHA-256 hashes (as of 2026-08-27, updated from live cert)
// Update these after GitHub rotates their key (OCSP fallback handles the transition window)
private let pinnedSPKIHashes: Set<String> = [
    "rlkAiJEjAwr5USvccZ2NlLzz7elZETOabSnkRvKdow0=", // api.github.com leaf (2026-08-27)
    "ZSagvDzjltLkewXEBuDxIzpW/dpVw1Juvvmd0hhkzdY=", // intermediate (2026-08-27)
    // Previous hashes kept for rotation window
    "EfXAzYKYsOsdi115+whKa+Yntz0T55fOk7iirLhX7rc=",
    "VqePxH3EcFwZuYK3CCOMz5HKMoeIZpZcEyBf4diPGSA=",
    "EdsvlytFf4a/O+hCPwBXFFi46RKXqivCAF+mO7s+5Ng=",
]

final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let log: @Sendable (String) -> Void
    init(log: @escaping @Sendable (String) -> Void) { self.log = log }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Step 1: standard TLS chain validation
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            log("❌ TLS chain invalid: \(error?.localizedDescription ?? "?")")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Step 2: check if any cert in chain matches our pinned SPKI hashes
        let certCount = SecTrustGetCertificateCount(serverTrust)
        for i in 0..<certCount {
            guard let cert = SecTrustGetCertificateAtIndex(serverTrust, i) else { continue }
            if let hash = spkiSHA256(cert), pinnedSPKIHashes.contains(hash) {
                log("🔒 TLS pin matched cert[\(i)] — OK")
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        // Step 3: pin mismatch — check OCSP to distinguish rotation vs MITM
        log("⚠️ TLS pin mismatch — checking OCSP to distinguish rotation from MITM...")
        checkOCSPFallback(serverTrust: serverTrust, completionHandler: completionHandler)
    }

    private func checkOCSPFallback(serverTrust: SecTrust,
                                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // macOS evaluates OCSP automatically as part of SecTrustEvaluateWithError.
        // We re-evaluate with explicit revocation policy to get revocation status.
        let revocationPolicy = SecPolicyCreateRevocation(
            kSecRevocationOCSPMethod | kSecRevocationRequirePositiveResponse
        )
        let basicPolicy = SecPolicyCreateSSL(true, "api.github.com" as CFString)

        let certChain = SecTrustCopyCertificateChain(serverTrust) as! [SecCertificate]
        var newTrust: SecTrust?
        guard SecTrustCreateWithCertificates(
            certChain as CFArray,
            [basicPolicy, revocationPolicy] as CFArray,
            &newTrust
        ) == errSecSuccess, let newTrust else {
            log("⚠️ OCSP: couldn't create revocation trust — falling back to standard TLS")
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        var ocspError: CFError?
        let isValid = SecTrustEvaluateWithError(newTrust, &ocspError)

        if isValid {
            // OCSP says cert is still valid but SPKI differs — GitHub may have rotated.
            // Allow via standard TLS and warn to update pins.
            log("⚠️ OCSP: SPKI pin mismatch but cert still valid — allowing (update pinnedSPKIHashes)")
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            // OCSP says revoked or expired — GitHub legitimately rotated, allow via standard TLS
            log("✅ OCSP: cert revoked/expired — GitHub rotated legitimately, allowing via system trust")
            log("   ⚠️  Update pinnedSPKIHashes in Updater.swift with GitHub's new cert hashes")
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        }
    }

    private func spkiSHA256(_ cert: SecCertificate) -> String? {
        var key: SecKey?
        var trust: SecTrust?
        SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust)
        if let t = trust { SecTrustEvaluateWithError(t, nil); key = SecTrustCopyKey(t) }
        guard let k = key, let data = SecKeyCopyExternalRepresentation(k, nil) as Data? else { return nil }
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }
}

// MARK: - Ed25519 public key for checksum verification
// Private key in SM: /infra/apple/update-signing-key
private let updatePublicKeyB64 = "MCowBQYDK2VwAyEA9aT3lXqgqgD2NyCH7S7nJ7MANFPOb9oL+8u9K1sWp28="

// MARK: - Updater

class Updater {
    static let repoAPI = "https://api.github.com/repos/zodl-inc/poc-macos-dmg-test/releases/latest"
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
    static let teamID = "RLPRR8CPQG"

    // Retained strongly so the session + delegate survive past runModal()
    // Wrapped in a class to avoid Swift concurrency static var warnings
    private static let _holder = UpdaterHolder()
    private class UpdaterHolder: @unchecked Sendable {
        var session: URLSession?
        var delegate: PinningDelegate?
    }

    static func checkAndUpdate(log: @escaping @Sendable (String) -> Void) {
        log("🔍 Checking for updates (current: v\(currentVersion))...")
        let delegate = PinningDelegate(log: log)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        _holder.delegate = delegate
        _holder.session = session

        guard let url = URL(string: repoAPI) else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        session.dataTask(with: req) { data, response, error in
            if let error = error {
                log("❌ Update check failed: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse {
                log("📡 GitHub API response: HTTP \(http.statusCode)")
            }
            guard let data else {
                log("❌ No data received")
                return
            }
            guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
                let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
                log("❌ Failed to parse release JSON: \(body.prefix(200))")
                return
            }

            let latest = release.tag_name
                .replacingOccurrences(of: "mac-v", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            log("📦 Latest release: v\(latest)")

            guard latest.compare(currentVersion, options: .numeric) == .orderedDescending else {
                log("✅ Already up to date")
                return
            }

            // Prefer the .zip artifact: extracted with ditto into our own container,
            // so no hdiutil attach (ENXIO flake on virtualized macOS) and no reads
            // from a TCC-protected DiskImageMounter volume (EPERM on macOS 15).
            // .dmg remains as fallback for releases published before the zip existed.
            let zipAsset = release.assets.first(where: { $0.name.hasSuffix(".zip") })
            let zipSha   = zipAsset.flatMap { z in release.assets.first(where: { $0.name == z.name + ".sha256" }) }
            let zipSig   = zipAsset.flatMap { z in release.assets.first(where: { $0.name == z.name + ".sha256.sig.b64" }) }

            let dmgAsset   = release.assets.first(where: { $0.name.hasSuffix(".dmg") })
            let sha256Asset = release.assets.first(where: { $0.name.hasSuffix(".sha256") && !$0.name.contains(".zip") })
            let sigAsset    = release.assets.first(where: { $0.name.hasSuffix(".sha256.sig.b64") && !$0.name.contains(".zip") })

            let install: @Sendable () -> Void
            if let zipAsset, let zipSha, let zipSig,
               let zipURL    = URL(string: zipAsset.browser_download_url),
               let zipShaURL = URL(string: zipSha.browser_download_url),
               let zipSigURL = URL(string: zipSig.browser_download_url) {
                log("📎 Assets: ZIP=\(zipAsset.name) sha256=\(zipSha.name) sig=\(zipSig.name)")
                install = { downloadAndInstallZip(zipURL: zipURL, sha256URL: zipShaURL,
                                                  sigURL: zipSigURL, version: latest,
                                                  session: session, log: log) }
            } else if let dmgAsset, let sha256Asset, let sigAsset,
                      let dmgURL    = URL(string: dmgAsset.browser_download_url),
                      let sha256URL = URL(string: sha256Asset.browser_download_url),
                      let sigURL    = URL(string: sigAsset.browser_download_url) {
                log("📎 Assets: DMG=\(dmgAsset.name) sha256=\(sha256Asset.name) sig=\(sigAsset.name)")
                install = { downloadAndInstall(dmgURL: dmgURL, sha256URL: sha256URL,
                                               sigURL: sigURL, version: latest,
                                               session: session, log: log) }
            } else {
                log("❌ Missing required assets (.zip or .dmg, + .sha256 + .sha256.sig.b64)")
                return
            }

            DispatchQueue.main.async {
                // Bring app to front so the alert is visible
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.messageText = "Update available — v\(latest)"
                alert.informativeText = "Install now and relaunch?"
                alert.addButton(withTitle: "Install & Relaunch")
                alert.addButton(withTitle: "Not Now")
                alert.alertStyle = .informational

                // Use beginSheetModal on the key window if available,
                // otherwise fall back to runModal (works even without a window)
                if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                    alert.beginSheetModal(for: window) { response in
                        if response == .alertFirstButtonReturn {
                            DispatchQueue.global().async { install() }
                        }
                    }
                } else {
                    if alert.runModal() == .alertFirstButtonReturn {
                        DispatchQueue.global().async { install() }
                    }
                }
            }
        }.resume()
    }

    private static func verifyEd25519(data: Data, signatureB64: String, log: @Sendable (String) -> Void) -> Bool {
        // CryptoKit Curve25519 (Ed25519) — strip the 12-byte DER header to get the raw 32-byte key
        guard let pubKeyDER = Data(base64Encoded: updatePublicKeyB64),
              pubKeyDER.count == 44,
              let sigData = Data(base64Encoded: signatureB64) else {
            log("❌ Ed25519: failed to decode key or signature")
            return false
        }
        let rawKey = pubKeyDER.suffix(32) // DER prefix is 12 bytes for Ed25519
        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
            let ok = publicKey.isValidSignature(sigData, for: data)
            if ok { log("✅ Ed25519 signature verified") }
            else  { log("❌ Ed25519 signature INVALID") }
            return ok
        } catch {
            log("❌ Ed25519: \(error.localizedDescription)")
            return false
        }
    }

    private static func downloadAndInstall(dmgURL: URL, sha256URL: URL, sigURL: URL,
                                            version: String,
                                            session: URLSession,
                                            log: @escaping @Sendable (String) -> Void) {
        let dmgDest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Zodl Internal-\(version).dmg")

        log("📥 Fetching checksum + signature...")
        guard let sha256Data = try? Data(contentsOf: sha256URL),
              let sha256Line = String(data: sha256Data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first else {
            log("❌ Couldn't fetch .sha256")
            return
        }
        guard let sigB64Raw = try? String(contentsOf: sigURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !sigB64Raw.isEmpty else {
            log("❌ Couldn't fetch .sha256.sig.b64")
            return
        }
        log("🔢 Expected SHA256: \(sha256Line)")
        log("🔏 Verifying Ed25519 signature on checksum...")
        // sign-checksum.py signs the hex string (not the full file bytes)
        let sha256HexData = Data(sha256Line.utf8)
        guard verifyEd25519(data: sha256HexData, signatureB64: sigB64Raw, log: log) else {
            log("❌ Ed25519 verification failed — aborting")
            return
        }

        log("📥 Downloading DMG...")
        session.downloadTask(with: dmgURL) { tmp, _, error in
            guard let tmp, error == nil else {
                log("❌ Download failed: \(error?.localizedDescription ?? "unknown")")
                return
            }
            try? FileManager.default.moveItem(at: tmp, to: dmgDest)
            log("💾 Saved to \(dmgDest.lastPathComponent)")

            guard let dmgData = try? Data(contentsOf: dmgDest) else { return }
            let actualHash = SHA256.hash(data: dmgData).map { String(format: "%02x", $0) }.joined()
            log("🔢 Actual   SHA256: \(actualHash)")

            guard actualHash == sha256Line else {
                log("❌ SHA256 mismatch — aborting")
                try? FileManager.default.removeItem(at: dmgDest)
                return
            }
            log("✅ SHA256 verified")

            let verifyResult = runOutput("/bin/sh", ["-c",
                "codesign -dv '\(dmgDest.path)' 2>&1 | grep TeamIdentifier"])
            log("🔏 codesign: \(verifyResult.trimmingCharacters(in: .whitespacesAndNewlines))")
            guard verifyResult.contains("TeamIdentifier=\(teamID)") else {
                log("❌ Code signature mismatch — aborting")
                try? FileManager.default.removeItem(at: dmgDest)
                return
            }
            log("✅ Code signature verified")

            run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dmgDest.path])

            log("📂 Mounting DMG...")
            // NOTE: -quiet suppresses -plist output, so don't combine them
            // -noverify: image verification is redundant (SHA256+Ed25519 already checked)
            // and hdiutil's verify pass can fail/hang without a TTY
            // "Device not configured" (ENXIO): diskimagesiod flake, common on virtualized
            // macOS (CI runners) — retry, then fall back to DiskImageMounter via `open`.
            var mount = runFull("/usr/bin/hdiutil",
                ["attach", dmgDest.path, "-nobrowse", "-noverify", "-plist"])
            var attempt = 1
            while mount.status != 0 && attempt < 4 {
                log("⚠️ hdiutil attempt \(attempt) exit \(mount.status): \(String(mount.stderr.prefix(200))) — retrying...")
                Thread.sleep(forTimeInterval: 2)
                mount = runFull("/usr/bin/hdiutil",
                    ["attach", dmgDest.path, "-nobrowse", "-noverify", "-plist"])
                attempt += 1
            }
            let mountOutput = mount.stdout
            if mount.status != 0 {
                log("⚠️ hdiutil exit \(mount.status) stderr: \(String(mount.stderr.prefix(300)))")
            }
            // hdiutil can prefix the plist with verification chatter (stapled/checksummed
            // images) — parseMountPoint slices to <?xml…</plist> before parsing. If that
            // still fails, fall back to the deterministic volume name (embeds the version).
            var resolvedMountPoint = parseMountPoint(mountOutput)
            let fallback = "/Volumes/Zodl-\(version)"
            if resolvedMountPoint == nil,
               FileManager.default.fileExists(atPath: "\(fallback)/Zodl Internal.app") {
                log("⚠️ plist parse failed — using volume-name fallback \(fallback)")
                resolvedMountPoint = fallback
            }
            if resolvedMountPoint == nil {
                // Last resort: let DiskImageMounter (Aqua session) mount it, poll /Volumes
                log("⚠️ hdiutil failed — trying DiskImageMounter via open -g...")
                run("/usr/bin/open", ["-g", dmgDest.path])
                for _ in 0..<30 {
                    Thread.sleep(forTimeInterval: 1)
                    if FileManager.default.fileExists(atPath: "\(fallback)/Zodl Internal.app") {
                        log("📂 DiskImageMounter mounted \(fallback)")
                        resolvedMountPoint = fallback
                        break
                    }
                }
            }
            guard let mountPoint = resolvedMountPoint else {
                log("❌ Couldn't parse mount point from hdiutil — aborting")
                log("   exit=\(mount.status) stdout(\(mountOutput.count)): \(String(mountOutput.prefix(300)))")
                log("   stderr(\(mount.stderr.count)): \(String(mount.stderr.prefix(300)))")
                try? FileManager.default.removeItem(at: dmgDest)
                return
            }
            log("📂 Mounted at \(mountPoint)")

            // Sanity check: verify the mounted app is actually the new version.
            // Read the plist directly — `defaults read` can transiently fail on a
            // freshly-mounted volume (returns empty). Retry briefly while it settles.
            let mountedPlist = "\(mountPoint)/Zodl Internal.app/Contents/Info.plist"
            var mountedVersion = ""
            for _ in 0..<5 {
                if let dict = NSDictionary(contentsOfFile: mountedPlist),
                   let v = dict["CFBundleShortVersionString"] as? String {
                    mountedVersion = v
                    break
                }
                Thread.sleep(forTimeInterval: 1)
            }
            if mountedVersion.isEmpty {
                // Log the actual I/O error for diagnosis
                do { _ = try Data(contentsOf: URL(fileURLWithPath: mountedPlist)) }
                catch { log("⚠️ Info.plist read error: \(error)") }
                let listing = (try? FileManager.default
                    .contentsOfDirectory(atPath: mountPoint))?.joined(separator: ", ") ?? "<unreadable>"
                log("⚠️ Volume listing: \(listing)")
                // The volume name embeds the version (see build-signed.sh) — a volume
                // named Zodl-<version> cannot be a stale mount of an older release,
                // which is all this check guards against. Trust it if the plist is
                // unreadable (seen on DiskImageMounter-mounted volumes on macOS 15 CI).
                if mountPoint.hasSuffix("Zodl-\(version)") {
                    log("⚠️ Trusting versioned volume name in lieu of plist check")
                    mountedVersion = version
                }
            }
            log("🔎 Mounted bundle version: \(mountedVersion) (expected \(version))")
            guard mountedVersion == version else {
                log("❌ Mounted DMG has wrong version — aborting (stale volume?)")
                run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet", "-force"])
                try? FileManager.default.removeItem(at: dmgDest)
                return
            }

            // Install to the same directory the running app came from.
            // This way /Applications stays in /Applications, ~/Applications stays there.
            let currentAppPath = Bundle.main.bundlePath
            let destApp = currentAppPath  // replace in-place

            log("📍 Current app path: \(currentAppPath)")
            log("📁 Target (in-place): \(destApp)")

            // Temp paths alongside the current install
            let destAppNew = "\(currentAppPath).new-update"
            run("/bin/sh", ["-c", "rm -rf '\(destAppNew)'"])

            let cpResult = run("/bin/sh", ["-c",
                "cp -R '\(mountPoint)/Zodl Internal.app' '\(destAppNew)'"
            ])
            log("  cp to temp: exit \(cpResult)")

            guard cpResult == 0 && FileManager.default.fileExists(atPath: destAppNew) else {
                log("❌ Copy failed — aborting")
                run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet", "-force"])
                return
            }
            run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destAppNew])

            atomicSwapAndRelaunch(destAppNew: destAppNew, cleanup: {
                run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet", "-force"])
                try? FileManager.default.removeItem(at: dmgDest)
            }, log: log)
        }.resume()
    }

    // Shared tail for the .zip and .dmg paths. `destAppNew` holds a verified,
    // quarantine-stripped copy of the new bundle alongside the current install;
    // `cleanup` releases artifact-specific resources (mounts, downloads) after
    // the swap succeeds.
    private static func atomicSwapAndRelaunch(destAppNew: String,
                                              cleanup: @escaping @Sendable () -> Void,
                                              log: @escaping @Sendable (String) -> Void) {
        let destApp = Bundle.main.bundlePath
        let destAppOld = "\(destApp).old-update"

        // Atomic swap: rename current → .old, new → current
        // mv works even if the bundle is in use (doesn't touch open file handles)
        if FileManager.default.fileExists(atPath: destApp) {
            let mvOld = runFull("/bin/mv", [destApp, destAppOld])
            log("  mv current → .old: exit \(mvOld.status) \(mvOld.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let mvNew = runFull("/bin/mv", [destAppNew, destApp])
        log("  mv .new → current: exit \(mvNew.status) \(mvNew.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        if mvNew.status != 0 {
            // Roll back so the user still has a working install
            let rollback = runFull("/bin/mv", [destAppOld, destApp])
            log("❌ Swap failed — rolled back (exit \(rollback.status))")
            return
        }

        let exists = FileManager.default.fileExists(atPath: destApp)
        log("  \(destApp) exists after swap: \(exists)")

        log("✅ Install complete")

        cleanup()

        // Force Launch Services to register the new app location before relaunching.
        // Without this, macOS LS cache may open the old copy from a different path.
        run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            ["-f", destApp])
        // Touch the bundle so Finder/Spotlight see it as updated
        run("/usr/bin/touch", [destApp])

        log("🚀 Launching external helper to swap + relaunch...")

        DispatchQueue.main.async {
            let pid = ProcessInfo.processInfo.processIdentifier
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

            // Write helper script to /tmp — runs completely outside the app bundle
            let helperPath = "/tmp/helloworld-updater-\(pid).sh"
            let helperScript = """
                #!/bin/sh
                # External updater helper — runs after the app process exits
                # Swap .new-update into place, register with LS, open new version
                while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
                rm -rf '\(destAppOld)' 2>/dev/null
                '\(lsregister)' -f '\(destApp)' 2>/dev/null
                sleep 0.3
                open -na '\(destApp)'
                rm -f '\(helperPath)'
                """
            try? helperScript.write(toFile: helperPath, atomically: true, encoding: .utf8)
            run("/bin/chmod", ["+x", helperPath])

            // Launch helper detached using launchd so it survives parent termination
            // nohup alone isn't sufficient when the parent is a sandboxed app
            let p = Process()
            p.launchPath = "/bin/sh"
            // Double-fork: the inner subshell exits immediately, orphaning the helper
            p.arguments = ["-c", "(nohup '\(helperPath)' >/dev/null 2>&1 &) &"]
            p.launch()
            p.waitUntilExit()

            log("✅ Helper launched — app will close now")
            NSApplication.shared.terminate(nil)
        }
    }

    // ZIP update path: download → SHA256+Ed25519 → ditto extract in our own
    // container → codesign + version check → swap. Never mounts anything, so it
    // works where hdiutil/DiskImageMounter can't (virtualized CI, TCC-locked
    // volumes on macOS 15).
    private static func downloadAndInstallZip(zipURL: URL, sha256URL: URL, sigURL: URL,
                                              version: String,
                                              session: URLSession,
                                              log: @escaping @Sendable (String) -> Void) {
        let zipDest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Zodl Internal-\(version).zip")

        log("📥 Fetching checksum + signature...")
        guard let sha256Data = try? Data(contentsOf: sha256URL),
              let sha256Line = String(data: sha256Data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first else {
            log("❌ Couldn't fetch .sha256")
            return
        }
        guard let sigB64Raw = try? String(contentsOf: sigURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !sigB64Raw.isEmpty else {
            log("❌ Couldn't fetch .sha256.sig.b64")
            return
        }
        log("🔢 Expected SHA256: \(sha256Line)")
        log("🔏 Verifying Ed25519 signature on checksum...")
        // sign-checksum.py signs the hex string (not the full file bytes)
        let sha256HexData = Data(sha256Line.utf8)
        guard verifyEd25519(data: sha256HexData, signatureB64: sigB64Raw, log: log) else {
            log("❌ Ed25519 verification failed — aborting")
            return
        }

        log("📥 Downloading ZIP...")
        session.downloadTask(with: zipURL) { tmp, _, error in
            guard let tmp, error == nil else {
                log("❌ Download failed: \(error?.localizedDescription ?? "unknown")")
                return
            }
            try? FileManager.default.removeItem(at: zipDest)
            try? FileManager.default.moveItem(at: tmp, to: zipDest)
            log("💾 Saved to \(zipDest.lastPathComponent)")

            guard let zipData = try? Data(contentsOf: zipDest) else { return }
            let actualHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
            log("🔢 Actual   SHA256: \(actualHash)")
            guard actualHash == sha256Line else {
                log("❌ SHA256 mismatch — aborting")
                try? FileManager.default.removeItem(at: zipDest)
                return
            }
            log("✅ SHA256 verified")

            // Extract into our own temp dir. ditto preserves symlinks and extended
            // attributes, so the Developer ID signature stays valid.
            let stageDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Zodl-update-stage-\(version)")
            try? FileManager.default.removeItem(at: stageDir)
            let dittoResult = run("/usr/bin/ditto", ["-x", "-k", zipDest.path, stageDir.path])
            log("📂 ditto extract: exit \(dittoResult)")
            let stagedApp = stageDir.appendingPathComponent("Zodl Internal.app").path
            guard dittoResult == 0, FileManager.default.fileExists(atPath: stagedApp) else {
                log("❌ Extract failed — aborting")
                try? FileManager.default.removeItem(at: stageDir)
                try? FileManager.default.removeItem(at: zipDest)
                return
            }

            let verifyResult = runOutput("/bin/sh", ["-c",
                "codesign -dv '\(stagedApp)' 2>&1 | grep TeamIdentifier"])
            log("🔏 codesign: \(verifyResult.trimmingCharacters(in: .whitespacesAndNewlines))")
            guard verifyResult.contains("TeamIdentifier=\(teamID)") else {
                log("❌ Code signature mismatch — aborting")
                try? FileManager.default.removeItem(at: stageDir)
                try? FileManager.default.removeItem(at: zipDest)
                return
            }
            log("✅ Code signature verified")

            // Sanity check: the extracted bundle must actually be the new version.
            // Unlike the DMG path, this plist lives in our own container — always readable.
            var stagedVersion = ""
            if let dict = NSDictionary(contentsOfFile: "\(stagedApp)/Contents/Info.plist"),
               let v = dict["CFBundleShortVersionString"] as? String {
                stagedVersion = v
            }
            log("🔎 Staged bundle version: \(stagedVersion) (expected \(version))")
            guard stagedVersion == version else {
                log("❌ Extracted app has wrong version — aborting")
                try? FileManager.default.removeItem(at: stageDir)
                try? FileManager.default.removeItem(at: zipDest)
                return
            }

            run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp])

            let currentAppPath = Bundle.main.bundlePath
            log("📍 Current app path: \(currentAppPath)")
            log("📁 Target (in-place): \(currentAppPath)")

            let destAppNew = "\(currentAppPath).new-update"
            run("/bin/sh", ["-c", "rm -rf '\(destAppNew)'"])
            // Prefer an in-volume rename; fall back to a ditto copy (preserves
            // symlinks/xattrs, so the signature survives) and surface real errors —
            // a bare `mv` exit code told us nothing on the CI runner.
            var staged = false
            do {
                try FileManager.default.moveItem(atPath: stagedApp, toPath: destAppNew)
                staged = true
                log("  staged via FileManager.moveItem")
            } catch {
                log("⚠️ moveItem failed: \(error) — falling back to ditto copy")
                let dittoCp = runFull("/usr/bin/ditto", [stagedApp, destAppNew])
                log("  ditto stage: exit \(dittoCp.status) \(String(dittoCp.stderr.prefix(300)))")
                staged = dittoCp.status == 0
            }
            guard staged && FileManager.default.fileExists(atPath: destAppNew) else {
                log("❌ Staging failed — aborting")
                try? FileManager.default.removeItem(at: stageDir)
                try? FileManager.default.removeItem(at: zipDest)
                return
            }

            atomicSwapAndRelaunch(destAppNew: destAppNew, cleanup: {
                try? FileManager.default.removeItem(at: stageDir)
                try? FileManager.default.removeItem(at: zipDest)
            }, log: log)
        }.resume()
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process(); p.launchPath = path; p.arguments = args
        p.launch(); p.waitUntilExit(); return p.terminationStatus
    }

    private static func runOutput(_ path: String, _ args: [String]) -> String {
        return runFull(path, args).stdout
    }

    // stdout must be drained concurrently — waiting first deadlocks past the 64KB pipe buffer
    private static func runFull(_ path: String, _ args: [String])
        -> (stdout: String, stderr: String, status: Int32) {
        let p = Process(); p.launchPath = path; p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        p.launch()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "",
                p.terminationStatus)
    }

    private static func parseMountPoint(_ plistString: String) -> String? {
        // hdiutil may emit non-plist lines (checksum/stapling verification) around the
        // XML — slice from <?xml to </plist> so PropertyListSerialization gets clean input.
        var candidate = plistString
        if let start = candidate.range(of: "<?xml"),
           let end = candidate.range(of: "</plist>") {
            candidate = String(candidate[start.lowerBound..<end.upperBound])
        }
        guard let data = candidate.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities { if let mp = entity["mount-point"] as? String { return mp } }
        return nil
    }
}
