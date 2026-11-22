/// Wire-format versions; a layout change bumps one -> .claude/conventions.md § protocol-versioning
public enum ProtocolVersion {
    public static let tap: UInt16 = 2
    public static let network: UInt16 = 4
}
