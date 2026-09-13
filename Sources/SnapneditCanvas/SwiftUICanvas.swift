#if canImport(SwiftUI)
import SwiftUI
import WebKit

/// The editor as a SwiftUI view.
///
/// ```swift
/// struct EditorScreen: View {
///     let config = SnapneditCanvasConfiguration(
///         credential: .publishableKey("pk_live_…", appId: "com.acme.photos")
///     )
///
///     var body: some View {
///         SnapneditCanvas(configuration: config)
///             .onReady { handle in
///                 try? await handle.loadImage(UIImage(named: "photo")!)
///             }
///             .onEvent { event in
///                 if case .job(let job) = event { print(job.status) }
///             }
///     }
/// }
/// ```
///
/// A boot failure — a refused key or app id, a malformed native app id, no
/// network — arrives through ``onFailure(_:)``, and through
/// ``onEvent(_:)`` as ``SnapneditCanvasEvent/error(_:)``.
@MainActor
public struct SnapneditCanvas {
    private let configuration: SnapneditCanvasConfiguration
    private var readyHandler: (@MainActor (SnapneditEditorHandle) async -> Void)?
    private var eventHandler: (@MainActor (SnapneditCanvasEvent) -> Void)?
    private var failureHandler: (@MainActor (SnapneditError) -> Void)?

    public init(configuration: SnapneditCanvasConfiguration) {
        self.configuration = configuration
    }

    /// Runs once, as soon as the editor reports `ready`. The handle it hands
    /// you is the same one calls are queued on, so this is a convenience
    /// rather than a requirement.
    public func onReady(_ action: @escaping @MainActor (SnapneditEditorHandle) async -> Void) -> SnapneditCanvas {
        var copy = self
        copy.readyHandler = action
        return copy
    }

    /// Runs for every event, including `ready`.
    public func onEvent(_ action: @escaping @MainActor (SnapneditCanvasEvent) -> Void) -> SnapneditCanvas {
        var copy = self
        copy.eventHandler = action
        return copy
    }

    /// Runs if the editor could not be created or never became ready.
    public func onFailure(_ action: @escaping @MainActor (SnapneditError) -> Void) -> SnapneditCanvas {
        var copy = self
        copy.failureHandler = action
        return copy
    }

    /// Everything the representable needs, in one value, so the platform-
    /// specific halves below stay a few lines each.
    fileprivate func buildCoordinator() -> Coordinator {
        Coordinator(configuration: configuration, onReady: readyHandler, onEvent: eventHandler, onFailure: failureHandler)
    }

    @MainActor
    public final class Coordinator {
        let configuration: SnapneditCanvasConfiguration
        var onReady: (@MainActor (SnapneditEditorHandle) async -> Void)?
        var onEvent: (@MainActor (SnapneditCanvasEvent) -> Void)?
        var onFailure: (@MainActor (SnapneditError) -> Void)?
        /// The live editor, once the view exists. `nil` when construction failed.
        public private(set) var canvas: SnapneditCanvasView?
        private var readyFired = false

        init(
            configuration: SnapneditCanvasConfiguration,
            onReady: (@MainActor (SnapneditEditorHandle) async -> Void)?,
            onEvent: (@MainActor (SnapneditCanvasEvent) -> Void)?,
            onFailure: (@MainActor (SnapneditError) -> Void)?
        ) {
            self.configuration = configuration
            self.onReady = onReady
            self.onEvent = onEvent
            self.onFailure = onFailure
        }

        /// Builds the canvas, or a plain view carrying the failure.
        func makeView() -> SnapneditPlatformView {
            do {
                let canvas = try SnapneditCanvasView(configuration: configuration)
                self.canvas = canvas
                canvas.handle.onEvent = { [weak self] event in self?.deliver(event, from: canvas.handle) }
                return canvas
            } catch let error as SnapneditError {
                onFailure?(error)
                return SnapneditPlatformView()
            } catch {
                onFailure?(SnapneditError(code: .internalError, message: "\(error)"))
                return SnapneditPlatformView()
            }
        }

        private func deliver(_ event: SnapneditCanvasEvent, from handle: SnapneditEditorHandle) {
            onEvent?(event)
            switch event {
            case .ready:
                guard !readyFired, let onReady else { return }
                readyFired = true
                Task { @MainActor in await onReady(handle) }
            case .error(let error) where !handle.isReady:
                onFailure?(error)
            default:
                break
            }
        }

        func tearDown() {
            canvas?.handle.destroy()
            canvas = nil
        }
    }
}

#if canImport(UIKit)
extension SnapneditCanvas: UIViewRepresentable {
    public func makeUIView(context: Context) -> SnapneditPlatformView {
        context.coordinator.makeView()
    }

    public func updateUIView(_ view: SnapneditPlatformView, context: Context) {
        // The closures are captured per-render; keep the coordinator's copies
        // current so a re-rendered parent's new closure is the one that runs.
        context.coordinator.onReady = readyHandler
        context.coordinator.onEvent = eventHandler
        context.coordinator.onFailure = failureHandler
    }

    public static func dismantleUIView(_ view: SnapneditPlatformView, coordinator: Coordinator) {
        // `dismantle` is nonisolated; the coordinator is main-actor bound.
        DispatchQueue.main.async { coordinator.tearDown() }
    }

    public func makeCoordinator() -> Coordinator { buildCoordinator() }
}
#elseif canImport(AppKit)
extension SnapneditCanvas: NSViewRepresentable {
    public func makeNSView(context: Context) -> SnapneditPlatformView {
        context.coordinator.makeView()
    }

    public func updateNSView(_ view: SnapneditPlatformView, context: Context) {
        context.coordinator.onReady = readyHandler
        context.coordinator.onEvent = eventHandler
        context.coordinator.onFailure = failureHandler
    }

    public static func dismantleNSView(_ view: SnapneditPlatformView, coordinator: Coordinator) {
        // `dismantle` is nonisolated; the coordinator is main-actor bound.
        DispatchQueue.main.async { coordinator.tearDown() }
    }

    public func makeCoordinator() -> Coordinator { buildCoordinator() }
}
#endif
#endif
