import XCTest

final class SigV4Tests: XCTestCase {
    // Example straight from the Amazon S3 "Signature Version 4" documentation:
    // GET /test.txt with a Range header.
    func testDocumentedAWSS3GetSignature() throws {
        let url = try XCTUnwrap(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt"))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")

        let signer = SigV4Signer(
            accessKeyID: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            sessionToken: nil,
            region: "us-east-1"
        )

        var components = DateComponents()
        components.year = 2013
        components.month = 5
        components.day = 24
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))

        signer.sign(&request, payloadHash: SigV4Signer.sha256Hex(Data()), now: date)

        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            authorization,
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        )
    }

    func testURIREncodingMatchesRFC3986() {
        XCTAssertEqual(SigV4Signer.uriEncode("photos/June 2024/é.jpg", encodeSlash: false), "photos/June%202024/%C3%A9.jpg")
        XCTAssertEqual(SigV4Signer.uriEncode("a+b=c", encodeSlash: true), "a%2Bb%3Dc")
        XCTAssertEqual(SigV4Signer.uriEncode("~unreserved-._", encodeSlash: true), "~unreserved-._")
        XCTAssertEqual(SigV4Signer.uriEncode("a/b", encodeSlash: true), "a%2Fb")
    }

    func testCanonicalQuerySortsAndEncodes() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/?b=2&a=hello%20world&a=1&list-type=2"))
        XCTAssertEqual(SigV4Signer.canonicalQuery(for: url), "a=1&a=hello%20world&b=2&list-type=2")
    }

    func testEmptyPayloadHash() {
        XCTAssertEqual(SigV4Signer.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testHostHeaderIncludesNonDefaultPort() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:9000/bucket/key"))
        XCTAssertEqual(SigV4Signer.hostHeader(for: url), "127.0.0.1:9000")
    }

    func testStreamingFileHashMatchesDataHash() throws {
        let data = Data((0..<200_000).map { UInt8($0 % 251) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try SigV4Signer.sha256Hex(contentsOfFile: url), SigV4Signer.sha256Hex(data))
    }
}
