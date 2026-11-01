import SwiftUI

/// First run: a gatefold opens to show the app, then sign-in.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened = false
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                GatefoldMark(opened: opened)
                    .frame(width: 180, height: 150)
                    .padding(.bottom, 36)
                    .accessibilityHidden(true)
                VStack(spacing: 12) {
                    Text("Gatefold")
                        .font(.system(size: 44, weight: .bold, design: .serif))
                        .foregroundStyle(Color.ink)
                    Text("Your PocketBook library, wherever you are. Pick up on your phone exactly where your InkPad left off.")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 380)
                }
                .opacity(opened ? 1 : 0)
                .offset(y: opened ? 0 : 12)
                Spacer(minLength: 20)
                VStack(spacing: 12) {
                    Button {
                        signingIn = true
                    } label: {
                        Text("Sign In with PocketBook Cloud")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.ribbon)
                    .accessibilityIdentifier("welcome.signIn")
                    Button("Read Without an Account") {
                        app.hasOnboarded = true
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ink)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("welcome.skip")
                }
                .frame(maxWidth: 420)
                .opacity(opened ? 1 : 0)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.paper)
            .navigationDestination(isPresented: $signingIn) { SignInFlow() }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 1.1, bounce: 0.12)) { opened = true }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: opened)
    }
}

/// The app's mark: a folded sheet whose two panels swing open around a ribbon.
struct GatefoldMark: View {
    var opened: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / 3
            let h = geo.size.height
            ZStack {
                // Centre panel with a ribbon.
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(light: 0xFFFDF8, dark: 0x2C2A27))
                    .frame(width: w, height: h)
                    .overlay(alignment: .top) {
                        RibbonShape().fill(Color.ribbon.gradient).frame(width: w * 0.2, height: h * 0.42)
                            .offset(x: w * 0.22)
                    }
                    .overlay {
                        VStack(alignment: .leading, spacing: h * 0.06) {
                            ForEach(0..<5, id: \.self) { i in
                                Capsule().fill(Color.ink.opacity(0.18)).frame(width: w * (i == 4 ? 0.4 : 0.66), height: 2.5)
                            }
                        }
                        .offset(y: h * 0.12)
                    }
                panel(w: w, h: h, leading: true)
                panel(w: w, h: h, leading: false)
            }
            .frame(width: geo.size.width, height: h)
            .shadow(color: .black.opacity(0.15), radius: 12, y: 8)
        }
    }

    private func panel(w: CGFloat, h: CGFloat, leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(
                colors: [Color(light: 0xF2E9D8, dark: 0x3A3631), Color(light: 0xE6DAC4, dark: 0x302D29)],
                startPoint: leading ? .trailing : .leading,
                endPoint: leading ? .leading : .trailing
            ))
            .frame(width: w, height: h)
            .rotation3DEffect(
                .degrees(opened ? 0 : (leading ? 178 : -178)),
                axis: (x: 0, y: 1, z: 0),
                anchor: leading ? .trailing : .leading,
                perspective: 0.5
            )
            .offset(x: leading ? -w : w)
    }
}

/// Email, then (when there's more than one) store, then password.
struct SignInFlow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum Step: Hashable { case email, store, password }

    @State private var step: Step = .email
    @State private var email = ""
    @State private var password = ""
    @State private var stores: [CloudStore] = []
    @State private var store: CloudStore?
    @State private var working = false
    @State private var error: String?
    @State private var failures = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title)
                .font(.display(.largeTitle, weight: .bold))
                .foregroundStyle(Color.ink)
                .contentTransition(.opacity)
            Text(subtitle)
                .foregroundStyle(.secondary)
            switch step {
            case .email:
                field {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.continue)
                        .onSubmit(next)
                        .accessibilityIdentifier("signIn.email")
                }
            case .store:
                VStack(spacing: 0) {
                    ForEach(stores) { s in
                        Button {
                            store = s
                            withAnimation(Motion.open) { step = .password }
                        } label: {
                            HStack {
                                Text(s.name).foregroundStyle(Color.ink)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("signIn.store.\(s.alias)")
                        if s != stores.last { Divider() }
                    }
                }
            case .password:
                field {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit(next)
                        .accessibilityIdentifier("signIn.password")
                }
                .modifier(Shake(amount: CGFloat(failures)))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .transition(.opacity)
                    .accessibilityIdentifier("signIn.error")
            }
            Spacer()
            if step != .store {
                Button(action: next) {
                    ZStack {
                        Text(step == .password ? "Sign In" : "Continue").opacity(working ? 0 : 1)
                        if working { ProgressView() }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .tint(.ribbon)
                .disabled(working || (step == .email ? email.isEmpty : password.isEmpty))
                .accessibilityIdentifier("signIn.continue")
            }
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
        .animation(Motion.open, value: step)
        .animation(.default, value: error)
        .sensoryFeedback(.error, trigger: failures)
        .onAppear { focused = true }
        .toolbar {
            if step != .email {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left") {
                        error = nil
                        step = step == .password && stores.count > 1 ? .store : .email
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(step != .email)
    }

    private var title: String {
        switch step {
        case .email: "Sign In"
        case .store: "Choose Your Store"
        case .password: "Password"
        }
    }

    private var subtitle: String {
        switch step {
        case .email: "Use the email you use for PocketBook Cloud on your InkPad."
        case .store: "\(email) has accounts in more than one PocketBook store."
        case .password: "For \(email)\(store.map { " at \($0.name)" } ?? "")."
        }
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .focused($focused)
            .font(.title3)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.ink.opacity(0.25)).frame(height: 1) }
    }

    private func next() {
        guard !working else { return }
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                switch step {
                case .email:
                    stores = try await app.sync.stores(forEmail: email.trimmingCharacters(in: .whitespaces))
                    if stores.count == 1 {
                        store = stores[0]
                        step = .password
                    } else if stores.isEmpty {
                        throw CloudError.noAccount
                    } else {
                        step = .store
                    }
                    focused = true
                case .password:
                    guard let store else { return }
                    let account = try await app.sync.signIn(email: email, password: password, store: store)
                    await app.didSignIn(account)
                case .store:
                    break
                }
            } catch {
                failures += 1
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(amount * .pi * 4), y: 0))
    }
}
