import Foundation

/// Pure session rules for the Host. Time arrives only through `now`; every
/// returned action is assumed to be carried out, so `gamePaused` follows it.
public struct HostSessionModel: Sendable {
  public enum Action: Equatable, Sendable { case neutralPads, pauseGame, resumeGame, requestKeyframe, holdAwake(Bool) }
  public enum Admission: Equatable, Sendable { case accept, busy(device: String) }
  public enum State: Equatable, Sendable { case idle, live(device: Data), detached }

  /// Seconds without any packet from the live client before the session detaches -> .claude/host.md § service
  public static let defaultSilenceTimeout: TimeInterval = 10

  private let inputTimeout: TimeInterval
  private let silenceTimeout: TimeInterval
  private let awakeGrace: TimeInterval

  public private(set) var state: State = .idle
  public private(set) var gameRunning = false
  public private(set) var gamePaused = false
  /// The live session plays: admitted resuming (`Hello.resume` absent or true) with a game that is not left paused, or it has
  /// since sent `launch` / `resume`. A library session (`resume: false`) does not until then -> .claude/portalkit.md § session-rules
  public private(set) var playing = false

  private var liveName = ""
  /// The device a game that starts with nobody playing is owed to: the last one admitted resuming or that played.
  private var lastDevice: Data?
  private var pausedBy: Data?
  private var lastPacket = Date.distantPast
  private var lastInput = Date.distantPast
  private var neutralSent = false
  private var leftAt = Date.distantPast
  private var awakeReleased = false

  public init(inputTimeout: TimeInterval = 0.5, silenceTimeout: TimeInterval = HostSessionModel.defaultSilenceTimeout, awakeGrace: TimeInterval = 600) {
    self.inputTimeout = inputTimeout
    self.silenceTimeout = silenceTimeout
    self.awakeGrace = awakeGrace
  }

  /// `resume: false` = a library session: admission never resumes the game, and a playing session of the same device it
  /// replaces stops playing (the game pauses). Another device is busy only while the live session plays; a library session
  /// gives way to it. `gameExists`: the Host has a game (starting, running or paused); a resuming admission with none plays
  /// nothing and is a library session like any other.
  public mutating func admit(device: Data, name: String, resume: Bool = true, gameExists: Bool = true, at now: Date) -> (Admission, [Action]) {
    if case .live(let current) = state {
      if current != device {
        // A library session (not playing) gives way: it leaves as `clientLeft` says and the newcomer is admitted afresh.
        guard !playing else { return (.busy(device: liveName), []) }
        let left = clientLeft(at: now)
        let (admission, actions) = admit(device: device, name: name, resume: resume, gameExists: gameExists, at: now)
        return (admission, left + actions)
      }
      restartTimers(at: now)
      guard resume else {
        playing = false
        guard gameRunning && !gamePaused else { return (.accept, []) }
        gamePaused = true
        pausedBy = device
        return (.accept, [.pauseGame])
      }
      // Plays a running game it reconnects to; a paused game stays paused (the device's `resume` resumes it) and the last
      // device is unchanged (`testALibrarySessionReplacingThePlayingOnePausesTheGame`).
      playing = gameExists && !gamePaused
      return (.accept, gameRunning && !gamePaused ? [.requestKeyframe] : [])
    }
    state = .live(device: device)
    liveName = name
    awakeReleased = false
    restartTimers(at: now)
    playing = false
    var actions: [Action] = [.holdAwake(true)]
    guard resume else { return (.accept, actions) }
    lastDevice = device
    if gamePaused && pausedBy == device {
      gamePaused = false
      actions += [.resumeGame, .requestKeyframe]
    }
    playing = gameExists && !gamePaused
    return (.accept, actions)
  }

  /// The live session sent `launch`: it plays from now on (the game it starts is not paused under it).
  public mutating func launchRequested(at now: Date) {
    guard case .live(let device) = state else { return }
    playing = true
    lastDevice = device
  }

  /// The launch the live session asked for failed: nothing plays.
  public mutating func launchFailed() {
    playing = false
  }

  public mutating func packetReceived(at now: Date) {
    lastPacket = now
  }

  public mutating func inputReceived(at now: Date) {
    lastPacket = now
    lastInput = now
    neutralSent = false
  }

  public mutating func clientLeft(at now: Date) -> [Action] {
    guard case .live(let device) = state else { return [] }
    var actions: [Action] = [.neutralPads]
    if gameRunning && !gamePaused {
      gamePaused = true
      pausedBy = device
      actions.append(.pauseGame)
    }
    state = .detached
    playing = false
    leftAt = now
    awakeReleased = false
    return actions
  }

  /// The live session plays from now on, whether or not the game was paused. `gameExists`: as in `admit`; with no game
  /// there is nothing to play, and the session stays what it was.
  public mutating func resumeRequested(gameExists: Bool = true, at now: Date) -> [Action] {
    guard case .live(let device) = state, gameExists else { return [] }
    playing = true
    lastDevice = device
    guard gamePaused else { return [] }
    gamePaused = false
    return [.resumeGame, .requestKeyframe]
  }

  public mutating func gameStarted(at now: Date) -> [Action] {
    gameRunning = true
    gamePaused = false
    if case .live = state, playing { return [] }
    gamePaused = true
    pausedBy = lastDevice
    return [.pauseGame]
  }

  /// The game is gone (a quit, a crash, an end by the Host): a session that played it is a library session now.
  public mutating func gameExited(at now: Date) -> [Action] {
    playing = false
    gameRunning = false
    gamePaused = false
    pausedBy = nil
    return []
  }

  public mutating func tick(at now: Date) -> [Action] {
    switch state {
    case .idle:
      return []
    case .live:
      if now.timeIntervalSince(lastPacket) >= silenceTimeout { return clientLeft(at: now) }
      if !neutralSent && now.timeIntervalSince(lastInput) >= inputTimeout {
        neutralSent = true
        return [.neutralPads]
      }
      return []
    case .detached:
      guard !awakeReleased, now.timeIntervalSince(leftAt) >= awakeGrace else { return [] }
      awakeReleased = true
      return [.holdAwake(false)]
    }
  }

  private mutating func restartTimers(at now: Date) {
    lastPacket = now
    lastInput = now
    neutralSent = false
  }
}
