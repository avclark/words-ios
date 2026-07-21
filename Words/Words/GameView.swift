import SwiftUI

/// Root screen: board, rack, action bar, floating drag layer.
/// Everything shares one named coordinate space so geometry can never drift
/// between the gesture math and the visuals.
struct GameView: View {
    static let spaceName = "game"

    var onExit: (() -> Void)? = nil

    @State private var state = BoardState()
    @State private var drag = DragController()

    var body: some View {
        GeometryReader { geo in
            let metrics = BoardMetrics.fitting(width: min(geo.size.width - 8, 440))
            // Rack must never exceed screen width: an over-wide child makes the
            // VStack overflow leading-aligned, shifting the whole layout off-center.
            // 90 = outer padding (24) + rack inner padding (24) + 6 gaps × 7.
            let rackTile = min(46, (geo.size.width - 90) / 7)

            VStack(spacing: 14) {
                header
                readout

                Spacer(minLength: 0)

                BoardView(state: state, drag: drag, metrics: metrics)
                    .frame(width: metrics.side, height: metrics.side)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                    // Pan the zoomed board by dragging empty squares.
                    // Tile drags are child gestures, so they win on tiles.
                    .gesture(boardPanGesture)
                    // Pinch toggles between the two zoom states.
                    .simultaneousGesture(pinchGesture(metrics: metrics))
                    .background(frameReporter { drag.boardFrame = $0; drag.metrics = metrics })

                RackView(state: state, drag: drag, tileSize: rackTile)
                    .background(frameReporter { drag.rackFrame = $0 })
                    .padding(.horizontal, 12)

                actionBar
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.05, green: 0.07, blue: 0.13).ignoresSafeArea())
            .overlay(alignment: .topLeading) { floatingTile }
        }
        .coordinateSpace(name: Self.spaceName)
        .sheet(isPresented: blankSheetShown) {
            BlankPickerView { letter in
                if let coord = state.pendingBlank {
                    state.assignBlank(at: coord, letter: letter)
                }
            }
            .interactiveDismissDisabled()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            if let onExit {
                Button(action: onExit) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
            Text("WORDS")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(Color.yellow)
                .kerning(4)
            Spacer()
            Text("board prototype")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 20)
    }

    /// Bare-bones game readout for testing — real design pass comes later.
    private var readout: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Score \(state.totalScore)")
                Spacer()
                Text("Turn \(state.turnNumber)")
                Spacer()
                Text("Bag \(state.bag.count)")
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))

            Group {
                switch state.status {
                case .rejected(let reason):
                    Text(reason).foregroundStyle(.red)
                case .played(let words, let score):
                    Text("Played \(words.joined(separator: ", ")) +\(score) · opponent passed")
                        .foregroundStyle(.green)
                case nil:
                    Text(" ")
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            ActionButton(icon: "shuffle", label: "Shuffle") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    state.shuffleRack()
                }
            }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    state.playMove()
                }
                drag.refreshZoom(state: state)
            } label: {
                Text(playLabel)
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(canPlay ? .black : .white.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        Capsule().fill(canPlay ? Color.yellow : Color.white.opacity(0.12))
                    )
            }
            .disabled(!canPlay)

            ActionButton(icon: "arrow.uturn.backward", label: "Recall") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    state.recallAll()
                }
                drag.refreshZoom(state: state)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var canPlay: Bool {
        state.currentScore() != nil && state.pendingBlank == nil
    }

    private var playLabel: String {
        if let score = state.currentScore() { return "PLAY  +\(score)" }
        return "PLAY"
    }

    @ViewBuilder
    private var floatingTile: some View {
        if let active = drag.active, let center = drag.visualCenter {
            TileView(tile: active.tile,
                     size: drag.floatingSize,
                     isFreshlyPlaced: true)
                // Translucent so the target square reads through the tile,
                // which sits directly under the finger (Scrabble GO-style).
                .opacity(active.isSettling ? 0.9 : 0.72)
                .scaleEffect(active.isSettling ? 0.85 : 1.0)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
                .position(center)
                .animation(.spring(response: 0.22, dampingFraction: 0.8), value: drag.floatingSize)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
                .zIndex(10)
        }
    }

    private var blankSheetShown: Binding<Bool> {
        Binding(
            get: { state.pendingBlank != nil && drag.active == nil },
            set: { shown in if !shown { /* dismissal blocked; pick a letter */ } }
        )
    }

    // MARK: - Board pan & pinch

    /// One-finger pan of the zoomed board. Only fires when the drag starts
    /// on an empty square (tile gestures are children and take priority),
    /// and the controller ignores it entirely at 1x zoom.
    private var boardPanGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named(Self.spaceName))
            .onChanged { value in
                drag.panChanged(translation: value.translation, state: state)
            }
            .onEnded { value in
                drag.panEnded(velocity: value.velocity)
            }
    }

    /// Pinch snaps between the two zoom states: out at 1x → zoom in
    /// centered on the pinch; in while zoomed → back to the full board.
    private func pinchGesture(metrics: BoardMetrics) -> some Gesture {
        MagnifyGesture()
            .onEnded { value in
                if !drag.isZoomedIn, value.magnification > 1.15 {
                    let p = CGPoint(x: value.startAnchor.x * metrics.side,
                                    y: value.startAnchor.y * metrics.side)
                    drag.zoomIn(centering: p)
                } else if drag.isZoomedIn, value.magnification < 0.87 {
                    drag.zoomOut()
                }
            }
    }

    /// Captures a view's frame in the shared game coordinate space.
    private func frameReporter(_ update: @escaping (CGRect) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { update(proxy.frame(in: .named(Self.spaceName))) }
                .onChange(of: proxy.frame(in: .named(Self.spaceName))) { _, frame in
                    update(frame)
                }
        }
    }
}

private struct ActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 62, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
    }
}

#Preview {
    GameView()
}
