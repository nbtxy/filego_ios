import Foundation

struct APIEnvelope<Payload: Decodable>: Decodable {
    let statusCode: Int
    let message: String?
    let data: Payload?
}

struct EmptyEnvelope: Decodable {
    let statusCode: Int
    let message: String?
}
