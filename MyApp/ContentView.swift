import SwiftUI
struct ContentView: View { @State private var tab = 0; @State private var zoom: Double = 1.0; @State private var light: Double = 0.5; @State private var vcamEnabled = true
var body: some View {
    ZStack {
        LinearGradient(
            colors: [.black, .blue.opacity(0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        VStack(spacing: 16) {

            HStack {
                Image(systemName: "camera.circle.fill")
                    .font(.title)

                Text("VCam")
                    .font(.title2.bold())

                Spacer()

                Button {
                } label: {
                    Image(systemName: "xmark")
                }
            }

            Picker("", selection: $tab) {
                Text("Control").tag(0)
                Text("Source").tag(1)
                Text("Light").tag(2)
            }
            .pickerStyle(.segmented)

            if tab == 0 {
                controlView
            }

            if tab == 1 {
                sourceView
            }

            if tab == 2 {
                lightView
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .padding(20)
    }
}

var controlView: some View {
    VStack(spacing: 16) {

        HStack {
            Button("↻ Rotate") { }

            Button("↔ Flip") { }
        }
        .buttonStyle(.borderedProminent)

        HStack {
            Button("−") {
                zoom = max(0.5, zoom - 0.1)
            }

            Text(String(format: "%.1fx", zoom))
                .frame(width: 70)

            Button("+") {
                zoom = min(3.0, zoom + 0.1)
            }
        }
        .font(.title2)

        VStack {
            Button("↑") { }

            HStack {
                Button("←") { }
                Button("●") { }
                Button("→") { }
            }

            Button("↓") { }
        }
        .font(.title)

        Button {
            vcamEnabled.toggle()
        } label: {
            Text(vcamEnabled ? "Disable VCam" : "Enable VCam")
                .frame(maxWidth: .infinity)
                .padding()
        }
        .buttonStyle(.borderedProminent)
        .tint(vcamEnabled ? .red : .green)

        HStack {
            Button("Hide") { }
            Button("Close") { }
        }
        .buttonStyle(.bordered)
    }
}

var sourceView: some View {
    VStack(spacing: 18) {

        HStack {
            Button("Select") { }
                .buttonStyle(.borderedProminent)

            Button("Clear") { }
                .buttonStyle(.bordered)
        }

        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: 3)
        ) {
            ForEach(1...6, id: \.self) { number in
                Button("\(number)") { }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }

        Button("⏸ Pause") { }
            .buttonStyle(.borderedProminent)
    }
}

var lightView: some View {
    VStack(alignment: .leading, spacing: 18) {

        Toggle("Face Lighting", isOn: .constant(true))

        Text("Intensity")

        Slider(value: $light, in: 0...1)

        Text("Light Direction")

        HStack {
            ForEach(["Front", "Top", "Bottom", "Left", "Right"], id: \.self) { item in
                Button(item) { }
                    .font(.caption)
            }
        }
    }
}
}
