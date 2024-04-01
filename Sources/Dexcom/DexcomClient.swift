//
//  DexcomClient.swift
//  Dexcom
//
//  Created by Kyle Bashour on 4/1/24.
//

import Foundation

public class DexcomClient {
    private let username: String
    private let password: String
    private let baseURL: URL

    private var accountID: UUID?
    private var sessionID: UUID?

    public init(
        username: String,
        password: String,
        outsideUS: Bool
    ) {
        self.username = username
        self.password = password
        self.baseURL = outsideUS ? .baseURLOUS : .baseURL
    }

    public func getGlucoseReadings(
        duration: Measurement<UnitDuration> = .maxGlucoseDuration,
        maxCount: Int = .maxGlucoseCount
    ) async throws -> [GlucoseReading] {
        do {
            try validateSessionID()
            return try await _getGlucoseReadings(duration: duration, maxCount: maxCount)
        } catch {
            try await createSession()
            return try await _getGlucoseReadings(duration: duration, maxCount: maxCount)
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
        let url = baseURL.appending(path: endpoint)

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw NSError()
        }

        if let params {
            components.queryItems = params.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        }

        guard let url = components.url else {
            throw NSError()
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept-Encoding")

        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        
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
                applicationId: .dexcomAppID
            )
        )
    }

    private func getSessionID() async throws -> UUID {
        guard let accountID else {
            throw NSError()
        }

        return try await post(
            endpoint: .loginEndpoint,
            body: GetSessionIDParams(
                accountId: accountID,
                password: password,
                applicationId: .dexcomAppID
            )
        )
    }

    private func createSession() async throws {
        accountID = try await getAccountID()
        sessionID = try await getSessionID()
    }

    private func validateSessionID() throws {
        if sessionID == nil {
            throw NSError()
        }
    }

    private func _getGlucoseReadings(
        duration: Measurement<UnitDuration>,
        maxCount: Int
    ) async throws -> [GlucoseReading] {
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