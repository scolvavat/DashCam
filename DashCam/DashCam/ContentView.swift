import SwiftUI

struct ContentView: View {
    @State private var hasMountedMainView = false

    var body: some View {
        ZStack {
            if hasMountedMainView {
                DashCamView()
                    .transition(.opacity)
            } else {
                DashCamLaunchPlaceholder()
                    .transition(.opacity)
            }
        }
        .task {
            guard !hasMountedMainView else { return }

            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))

            withAnimation(.easeOut(duration: 0.2)) {
                hasMountedMainView = true
            }
        }
    }
}

private struct DashCamLaunchPlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.07, green: 0.08, blue: 0.10),
                    Color(red: 0.18, green: 0.07, blue: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Image("LaunchBrandIcon")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 8)

                VStack(spacing: 8) {
                    Text("DashCam")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Opening live view...")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
