import Foundation

/// Looks a citation up in arXiv and zbMATH Open over the app's one network seam. It sends only the citation's query
/// (`CitationRules.query`), with no cookies and a short timeout, and reports what each index answered; it decides
/// nothing (`CitationRules.verdict` does).
nonisolated struct CitationLookupClient: Sendable {
    let transport: any HTTPTransport

    /// The most of a response read.
    static let responseLimit = 512 * 1024

    /// arXiv is asked for every word at once; if that finds nothing, it is asked again, after `pause`, for the first
    /// few (`CitationRules.narrowTerms`, usually the author and the title's first words).
    @concurrent func lookUp(_ raw: String, pause: Duration = .seconds(3)) async -> [(index: String, answer: IndexAnswer)] {
        let terms = CitationRules.terms(raw)
        var arxiv = await answer(Self.arxivRequest(terms), read: Self.parseArxiv)
        let narrow = CitationRules.narrowTerms(raw)
        if case .candidates(let found) = arxiv, found.isEmpty, narrow != terms, !Task.isCancelled {
            try? await Task.sleep(for: pause)
            arxiv = await answer(Self.arxivRequest(narrow), read: Self.parseArxiv)
        }
        // Stopped: nothing more is sent.
        guard !Task.isCancelled else { return [] }
        let zbmath = await answer(Self.zbmathRequest(CitationRules.query(raw)), read: Self.parseZbmath)
        return [("arXiv", arxiv), ("zbMATH Open", zbmath)]
    }

    private func answer(_ request: URLRequest?, read: (Int, Data) -> [CitationCandidate]?) async -> IndexAnswer {
        guard let request else { return .failed("the request could not be built") }
        do {
            let response = try await transport.open(request)
            var body = Data()
            for try await chunk in response.chunks {
                body.append(chunk)
                if body.count > Self.responseLimit { return .failed("the answer was too long") }
            }
            if response.status == 429 { return .failed("too many requests; try again later") }
            if response.status >= 500 { return .failed("the server answered \(response.status)") }
            guard let candidates = read(response.status, body) else {
                return .failed(response.status == 200 ? "the answer could not be read" : "the server answered \(response.status)")
            }
            return .candidates(candidates)
        } catch let error as URLError where error.code == .timedOut {
            return .failed("timed out")
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                             .cannotConnectToHost, .dnsLookupFailed].contains(error.code) {
            return .failed("offline")
        } catch {
            return .failed("the lookup failed")
        }
    }

    static func request(_ string: String) -> URLRequest? {
        guard let url = URL(string: string) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue("sangaku", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    // MARK: arXiv

    static func arxivRequest(_ terms: [String]) -> URLRequest? {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")
        components?.queryItems = [URLQueryItem(name: "search_query", value: terms.map { "all:" + $0 }.joined(separator: " AND ")),
                                  URLQueryItem(name: "max_results", value: "5")]
        return components?.url.flatMap { request($0.absoluteString) }
    }

    /// The entries of an arXiv Atom feed.
    static func parseArxiv(_ status: Int, _ data: Data) -> [CitationCandidate]? {
        guard status == 200 else { return nil }
        let reader = AtomReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.sawFeed else { return nil }
        return reader.entries
    }

    // MARK: zbMATH Open

    static func zbmathRequest(_ query: String) -> URLRequest? {
        var components = URLComponents(string: "https://api.zbmath.org/v1/document/_search")
        components?.queryItems = [URLQueryItem(name: "search_string", value: query),
                                  URLQueryItem(name: "results_per_page", value: "5")]
        return components?.url.flatMap { request($0.absoluteString) }
    }

    private struct ZbmathResponse: Decodable {
        struct Status: Decodable {
            var internalCode: String?

            enum CodingKeys: String, CodingKey {
                case internalCode = "internal_code"
            }
        }

        struct Document: Decodable {
            struct Title: Decodable {
                var title: String?
            }

            struct Contributors: Decodable {
                struct Author: Decodable {
                    var name: String
                }

                var authors: [Author]?
            }

            var title: Title?
            var year: String?
            var zbmathURL: String?
            var contributors: Contributors?

            enum CodingKeys: String, CodingKey {
                case title, year, contributors
                case zbmathURL = "zbmath_url"
            }
        }

        var result: [Document]?
        var status: Status?
    }

    /// zbMATH Open's documents. It answers "no results" with status 404 and a body saying so: that is an answer. An
    /// answer of 200 without a list of documents is not one.
    static func parseZbmath(_ status: Int, _ data: Data) -> [CitationCandidate]? {
        guard let response = try? JSONDecoder().decode(ZbmathResponse.self, from: data) else { return nil }
        if status == 404, response.status?.internalCode?.contains("No results found") == true { return [] }
        guard status == 200, let result = response.result else { return nil }
        return result.map { document in
            let names = (document.contributors?.authors ?? []).map(\.name)
            return CitationCandidate(index: "zbMATH Open", title: document.title?.title ?? "",
                                     surnames: names.map { String($0.split(separator: ",").first ?? Substring($0)) },
                                     year: document.year.flatMap { Int($0) }, url: document.zbmathURL, authors: names)
        }
    }
}

/// Collects an arXiv feed's entries: title, authors' surnames, the year first published and the abstract's page.
nonisolated final class AtomReader: NSObject, XMLParserDelegate {
    private(set) var entries: [CitationCandidate] = []
    private(set) var sawFeed = false
    private var current: CitationCandidate?
    private var text = ""
    private var inAuthor = false

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch element {
        case "feed": sawFeed = true
        case "entry": current = CitationCandidate(index: "arXiv", title: "", surnames: [], year: nil, url: nil)
        case "author": inAuthor = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "entry":
            if let current { entries.append(current) }
            current = nil
        case "title" where current != nil:
            current?.title = value.replacingOccurrences(of: "\n", with: " ")
        case "name" where inAuthor:
            if let surname = value.split(separator: " ").last { current?.surnames.append(String(surname)) }
            current?.authors.append(value)
        case "author":
            inAuthor = false
        case "published":
            current?.year = Int(value.prefix(4))
        case "id" where current != nil:
            current?.url = value.replacingOccurrences(of: "http://", with: "https://")
        default: break
        }
        text = ""
    }
}
