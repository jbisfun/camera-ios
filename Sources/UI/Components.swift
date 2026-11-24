import SwiftUI

/// setShadowIcon(): white icon with a soft shadow, tinted primary when checked.
struct ShadowIcon: View {
    @Environment(\.palette) private var palette
    let systemName: String
    var checked = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 22))
            .foregroundStyle(checked ? palette.primaryColor : .white)
            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
    }
}

/// ic_timer_*_vector: the timer glyph with its seconds.
struct TimerIcon: View {
    @Environment(\.palette) private var palette
    let mode: TimerMode
    var checked = false

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "timer")
                .font(.system(size: 20))
                .overlay {
                    if mode == .off {
                        Rectangle().frame(width: 2, height: 30).rotationEffect(.degrees(-45))
                    }
                }
            if mode != .off {
                Text("\(mode.seconds)").font(.system(size: 13, weight: .bold))
            }
        }
        .foregroundStyle(checked ? palette.primaryColor : .white)
        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
    }
}

/// ic_photo_*_vector / ic_video_*_vector: the ratio or quality in an outlined frame.
struct ResolutionIcon: View {
    @Environment(\.palette) private var palette
    let label: String
    var checked = false

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 4)
            .frame(minWidth: 30, minHeight: 22)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 2))
            .foregroundStyle(checked ? palette.primaryColor : .white)
            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
    }
}

/// ic_shutter_animated / ic_video_rec_animated / ic_shutter_timer_cancel.
struct ShutterButton: View {
    enum Kind { case photo, timerCancel, video, recording }
    let kind: Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 3)
                switch kind {
                case .photo:
                    Circle().fill(.white).padding(10)
                case .timerCancel:
                    Circle().fill(.white).padding(10)
                    Image(systemName: "xmark").font(.system(size: 22, weight: .medium)).foregroundStyle(.black)
                case .video:
                    Circle().fill(Color(argb: 0xFFE53935)).padding(10)
                case .recording:
                    RoundedRectangle(cornerRadius: 6).fill(Color(argb: 0xFFE53935)).frame(width: 30, height: 30)
                }
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
        }
        .buttonStyle(ShutterPressStyle())
        .animation(.easeInOut(duration: 0.2), value: kind)
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1)
    }
}

/// camera_button_background: a white ring around the last-media thumbnail / switch button.
struct RingButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// FocusCircleView: a primary-colored ring that disappears after 500 ms.
struct FocusCircle: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Circle().stroke(palette.primaryColor, lineWidth: 2).frame(width: 100, height: 100)
    }
}
