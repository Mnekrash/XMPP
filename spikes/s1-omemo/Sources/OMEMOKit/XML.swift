import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Minimal XML element tree for the spike (Foundation `XMLParser`, available on iOS and Linux).
public final class XMLNode: @unchecked Sendable {
    public let name: String
    public var attributes: [String: String]
    public var children: [XMLNode] = []
    public var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Local name without prefix.
    public var localName: String { name.split(separator: ":").last.map(String.init) ?? name }

    public func child(_ local: String) -> XMLNode? { children.first { $0.localName == local } }
    public func children(_ local: String) -> [XMLNode] { children.filter { $0.localName == local } }

    public static func parse(_ string: String) throws -> XMLNode {
        let delegate = TreeBuilder()
        let parser = XMLParser(data: Data(string.utf8))
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw OMEMOError.malformedXML(parser.parserError.map { "\($0)" } ?? "empty document")
        }
        return root
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLNode(name: elementName, attributes: attributeDict)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}

enum XMLEscape {
    static func text(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func attribute(_ s: String) -> String {
        text(s).replacingOccurrences(of: "'", with: "&apos;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
