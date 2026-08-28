import Darwin
import Foundation

struct GrabberRequest: Codable {
    enum Kind: String, Codable {
        case ping
        case acquire
        case heartbeat
        case release
    }

    let kind: Kind
    let locationID: Int?

    static let ping = Self(kind: .ping, locationID: nil)
    static func acquire(locationID: Int) -> Self { Self(kind: .acquire, locationID: locationID) }
    static let heartbeat = Self(kind: .heartbeat, locationID: nil)
    static let release = Self(kind: .release, locationID: nil)
}

struct GrabberResponse: Codable {
    let ok: Bool
    let message: String
    let capturing: Bool
}

final class GrabberLeaseClient {
    private let socketPath: String
    private let locationID: Int

    init(socketPath: String, locationID: Int) {
        self.socketPath = socketPath
        self.locationID = locationID
    }

    func acquire() throws {
        let response = try send(.acquire(locationID: locationID))
        guard response.ok, response.capturing else {
            throw CLIError.runtime("Privileged C100 grabber rejected lease: \(response.message)")
        }
    }

    func heartbeat() throws {
        let response = try send(.heartbeat)
        guard response.ok, response.capturing else {
            throw CLIError.runtime("Privileged C100 grabber lease was lost: \(response.message)")
        }
    }

    func release() {
        _ = try? send(.release)
    }

    private func send(_ request: GrabberRequest) throws -> GrabberResponse {
        try UnixSocketServer.send(request, path: socketPath, response: GrabberResponse.self)
    }
}

nonisolated(unsafe) private var grabberStopRequested: sig_atomic_t = 0

private func requestGrabberStop(_: Int32) {
    grabberStopRequested = 1
}

final class PrivilegedGrabberService {
    private static let leaseDuration: TimeInterval = 3

    private let socketPath: String
    private let ownerUID: uid_t
    private let ownerGID: gid_t
    private let allowedLocationID: Int
    private var capture: C100InputCapture?
    private var capturedLocationID: Int?
    private var leaseDeadline = Date.distantPast

    init(socketPath: String, ownerUID: uid_t, ownerGID: gid_t, allowedLocationID: Int) {
        self.socketPath = socketPath
        self.ownerUID = ownerUID
        self.ownerGID = ownerGID
        self.allowedLocationID = allowedLocationID
    }

    func run() throws {
        guard geteuid() == 0 else {
            throw CLIError.runtime("grabber-service must be launched by the installed root LaunchDaemon")
        }
        grabberStopRequested = 0
        Darwin.signal(SIGINT, requestGrabberStop)
        Darwin.signal(SIGTERM, requestGrabberStop)
        Darwin.signal(SIGPIPE, SIG_IGN)

        let server = try UnixSocketServer(path: socketPath, ownerUID: ownerUID, ownerGID: ownerGID)
        log(
            "started pid=\(getpid()) owner_uid=\(ownerUID) "
                + "location=\(String(format: "0x%X", allowedLocationID)) socket=\(socketPath)"
        )

        while grabberStopRequested == 0 {
            capture?.service()
            if capture != nil, Date() >= leaseDeadline {
                releaseCapture(reason: "lease_expired")
            }
            guard let client = try server.accept(timeoutMilliseconds: 10) else { continue }
            autoreleasepool {
                defer { Darwin.close(client) }
                do {
                    let data = try UnixSocketServer.readRequest(from: client)
                    let request = try JSONDecoder().decode(GrabberRequest.self, from: data)
                    try UnixSocketServer.write(handle(request), to: client)
                } catch {
                    try? UnixSocketServer.write(
                        GrabberResponse(ok: false, message: String(describing: error), capturing: capture != nil),
                        to: client
                    )
                }
            }
        }
        releaseCapture(reason: "service_stopping")
        log("stopped")
    }

    private func handle(_ request: GrabberRequest) -> GrabberResponse {
        do {
            switch request.kind {
            case .ping:
                return GrabberResponse(ok: true, message: "grabber service is running", capturing: capture != nil)
            case .acquire:
                let locationID = try Self.validateRequestedLocation(
                    request.locationID,
                    allowedLocationID: allowedLocationID
                )
                if let capturedLocationID, capturedLocationID != locationID {
                    throw CLIError.runtime(
                        "Grabber already holds location \(String(format: "0x%X", capturedLocationID))"
                    )
                }
                if capture == nil {
                    capture = try C100InputCapture.connect(locationID: locationID) { _ in }
                    capturedLocationID = locationID
                    log("capture acquired location=\(String(format: "0x%X", locationID))")
                }
                leaseDeadline = Date().addingTimeInterval(Self.leaseDuration)
                return GrabberResponse(ok: true, message: "capture lease acquired", capturing: true)
            case .heartbeat:
                guard capture != nil else {
                    throw CLIError.runtime("No active capture lease")
                }
                leaseDeadline = Date().addingTimeInterval(Self.leaseDuration)
                return GrabberResponse(ok: true, message: "capture lease renewed", capturing: true)
            case .release:
                releaseCapture(reason: "client_release")
                return GrabberResponse(ok: true, message: "capture lease released", capturing: false)
            }
        } catch {
            log("request failed kind=\(request.kind.rawValue) error=\(error)")
            return GrabberResponse(ok: false, message: String(describing: error), capturing: capture != nil)
        }
    }

    static func validateRequestedLocation(_ requestedLocationID: Int?, allowedLocationID: Int) throws -> Int {
        guard let requestedLocationID else {
            throw CLIError.runtime("Grabber acquire request is missing locationID")
        }
        guard requestedLocationID == allowedLocationID else {
            throw CLIError.runtime(
                "Grabber is restricted to location \(String(format: "0x%X", allowedLocationID)); "
                    + "requested \(String(format: "0x%X", requestedLocationID))"
            )
        }
        return requestedLocationID
    }

    private func releaseCapture(reason: String) {
        guard capture != nil else { return }
        capture = nil
        capturedLocationID = nil
        leaseDeadline = .distantPast
        log("capture released reason=\(reason)")
    }

    private func log(_ message: String) {
        print("c100-grabber: \(message)")
        fflush(stdout)
    }
}
