//
//  DexcomClient.swift
//  Dexcom
//
//  Created by Kyle Bashour on 4/1/24.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum DexcomClientError: Error {
    case failedToBuildURL
    case noAccountID
    case noSessionID
}

public protocol DexcomClientDelegate: AnyObject {
    func didUpdateAccountID(_ accountID: UUID)
    func didUpdateSessionID(_ sessionID: UUID)
}

public class DexcomClient {
    private let username: String
    private let password: String
    private let location: AccountLocation

    private var accountID: UUID? {
        didSet {
            if let accountID {
                delegate?.didUpdateAccountID(accountID)
            }
        }
    }

    private var sessionID: UUID? {
        didSet {
            if let sessionID {
                delegate?.didUpdateSessionID(sessionID)
            }
        }
    }

    public weak var delegate: DexcomClientDelegate?

    public init(
        username: String,
        password: String,
        existingAccountID: UUID? = nil,
        existingSessionID: UUID? = nil,
        accountLocation: AccountLocation
    ) {
        self.username = username
        self.password = password
        self.location = accountLocation
    }

    public func getGlucoseReadings(
        duration: Measurement<UnitDuration> = .maxGlucoseDuration,
        maxCount: Int = .maxGlucoseCount
    ) async throws -> [GlucoseReading] {
        do {
            try validateSessionID()
            return try await _getGlucoseReadings(duration: duration, maxCount: maxCount).map {
                GlucoseReading(
                    value: $0.value,
                    trend: $0.trend,
                    date: $0.date
                )
            }
        } catch {
            _ = try await createSession()
            return try await _getGlucoseReadings(duration: duration, maxCount: maxCount).map {
                GlucoseReading(
                    value: $0.value,
                    trend: $0.trend,
                    date: $0.date
                )
            }
        }
    }

    public func getLatestGlucoseReading() async throws -> GlucoseReading? {
        try await getGlucoseReadings(maxCount: 1).last
    }

    public func getCurrentGlucoseReading() async throws -> GlucoseReading? {
        try await getGlucoseReadings(duration: .init(value: 10, unit: .minutes), maxCount: 1).last
    }

    private func post<Body: Encodable, Response: Decodable>(
        endpoint: String,
        params: [String: String]? = nil,
        body: Body?
    ) async throws -> Response {
        let url = location.url.appendingPathComponent(endpoint)

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw DexcomClientError.failedToBuildURL
        }

        if let params {
            components.queryItems = params.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        }

        guard let url = components.url else {
            throw DexcomClientError.failedToBuildURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"

        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, _) = try await URLSession.shared.asyncData(for: request)

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw try JSONDecoder().decode(DexcomError.self, from: data)
        }
    }

    private func post<Response: Decodable>(endpoint: String, params: [String: String]? = nil) async throws -> Response {
        try await post(endpoint: endpoint, params: params, body: Optional<String>.none)
    }

    private func getAccountID() async throws -> UUID {
        try await post(
            endpoint: .authenticateEndpoint,
            body: GetAccountIDParams(
                accountName: username,
                password: password,
                applicationId: location.appID
            )
        )
    }

    private func getSessionID() async throws -> UUID {
        guard let accountID else {
            throw DexcomClientError.noAccountID
        }

        return try await post(
            endpoint: .loginEndpoint,
            body: GetSessionIDParams(
                accountId: accountID,
                password: password,
                applicationId: location.appID
            )
        )
    }

    public func createSession() async throws -> (accountID: UUID, sessionID: UUID) {
        let accountID = try await getAccountID()
        self.accountID = accountID

        let sessionID = try await getSessionID()
        self.sessionID = sessionID

        return (accountID, sessionID)
    }

    private func validateSessionID() throws {
        if sessionID == nil {
            throw DexcomClientError.noSessionID
        }
    }

    private func _getGlucoseReadings(
        duration: Measurement<UnitDuration>,
        maxCount: Int
    ) async throws -> [_GlucoseReading] {
        try await post(
            endpoint: .readingsEndpoint,
            params: [
                "sessionId": sessionID?.uuidString ?? "",
                "minutes": String(Int(duration.converted(to: .minutes).value)),
                "maxCount": String(maxCount),
            ]
        )
    }
}

private extension URLSession {
    func asyncData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    return continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data!, response!))
                }
            }

            task.resume()
        }
    }
}
