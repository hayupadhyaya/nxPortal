# Sourced by scripts/preflight.sh and the commit-msg hook; one place for the mapping.
# .claude/conventions.md § documentation-rule
# doc_for <path>: prints the topic doc (file name under .claude/) a structural change at <path> needs.
doc_for() {
  case "$1" in
    PortalKit/Sources/PortalKit/*|PortalKit/Sources/PortalTestSupport/*|PortalKit/Sources/portal-fakegame/*|PortalKit/Tests/PortalKitTests/*|PortalKit/Package.swift) echo portalkit.md ;;
    PortalKit/Sources/PortalHostCore/*|PortalKit/Sources/PortalHostModel/*|PortalKit/Tests/PortalHostModelTests/*|PortalKit/Sources/portal-hostd/*|PortalKit/Tests/PortalHostCoreTests/*|Host/*) echo host.md ;;
    PortalKit/Sources/PortalClientCore/*|PortalKit/Sources/PortalPlayer/*|PortalKit/Tests/PortalPlayerTests/*|PortalKit/Sources/portal-fakeclient/*|PortalKit/Tests/PortalClientCoreTests/*|Client/*) echo client.md ;;
  esac
}
