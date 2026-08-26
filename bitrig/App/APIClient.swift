import Foundation

actor SureAPIClient {
  private var baseURL: URL
  private var apiKey: String
  private var session: URLSession
  private var decoder: JSONDecoder

  init(baseURL: URL, apiKey: String) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    configuration.waitsForConnectivity = true
    session = URLSession(configuration: configuration)
    decoder = JSONDecoder()
  }

  func update(baseURL: URL, apiKey: String) {
    self.baseURL = baseURL
    self.apiKey = apiKey
  }

  func get<T: Decodable & Sendable>(_ path: String, as type: T.Type = T.self) async throws -> T {
    try await request(path: path, method: "GET", body: Optional<String>.none, as: type)
  }

  func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
    _ path: String,
    body: Body,
    as type: Response.Type = Response.self
  ) async throws -> Response {
    try await request(path: path, method: "POST", body: body, as: type)
  }

  func postWithoutResponse<Body: Encodable & Sendable>(_ path: String, body: Body) async throws {
    let _: EmptyResponse = try await request(path: path, method: "POST", body: body, as: EmptyResponse.self)
  }

  func delete(_ path: String) async throws {
    let _: EmptyResponse = try await request(
      path: path,
      method: "DELETE",
      body: Optional<String>.none,
      as: EmptyResponse.self
    )
  }

  private func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(
    path: String,
    method: String,
    body: Body?,
    as type: Response.Type
  ) async throws -> Response {
    let cleanedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
    guard let url = URL(string: cleanedPath, relativeTo: baseURL)?.absoluteURL else {
      throw SureAPIError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
    if let body {
      request.httpBody = try JSONEncoder().encode(body)
    }

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw SureAPIError.invalidResponse
    }
    guard 200..<300 ~= httpResponse.statusCode else {
      let serverError = try? decoder.decode(ServerError.self, from: data)
      throw SureAPIError.server(status: httpResponse.statusCode, message: serverError?.message ?? serverError?.error)
    }
    if Response.self == EmptyResponse.self, data.isEmpty {
      return EmptyResponse() as! Response
    }
    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw SureAPIError.decoding(error.localizedDescription)
    }
  }
}

struct EmptyResponse: Codable, Sendable {}

struct ServerError: Codable, Sendable {
  var error: String?
  var message: String?
}

enum SureAPIError: LocalizedError, Equatable {
  case invalidURL
  case invalidResponse
  case server(status: Int, message: String?)
  case decoding(String)

  var errorDescription: String? {
    switch self {
    case .invalidURL: "The server address is invalid."
    case .invalidResponse: "The server returned an invalid response."
    case let .server(status, message):
      message ?? "The server returned an error (\(status))."
    case let .decoding(message): "Sure returned data this app could not read: \(message)"
    }
  }
}
