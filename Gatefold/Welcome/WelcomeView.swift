import GatefoldCore
import SwiftUI

/// First run: a gatefold opens to show the app, then sign-in.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened = false
    /// The mark starts where the launch screen left it (closed, centred) and rises once it has opened.
    @State private var risen = false
    @State private var markCenter: CGFloat?
    @State private var screenCenter: CGFloat?
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                GatefoldMark(opened: opened)
                    .frame(width: GatefoldMark.size.width, height: GatefoldMark.size.height)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { markCenter = $0 }
                    .offset(y: risen ? 0 : max(0, (screenCenter ?? 0) - (markCenter ?? 0)))
                    .padding(.bottom, 36)
                    .accessibilityHidden(true)
                VStack(spacing: 12) {
                    Text("Gatefold")
                        .font(.wordmark(size: 44))
                        .foregroundStyle(Color.ink)
                    Text("Your PocketBook shelf, now in your pocket. Open a book and land on the very page your InkPad left off.")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.secondaryInk)
                        .frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 28)
                .opacity(risen ? 1 : 0)
                .offset(y: risen ? 0 : 12)
                Spacer(minLength: 20)
                VStack(spacing: 12) {
                    Button {
                        signingIn = true
                    } label: {
                        Text("Sign In with PocketBook Cloud")
                            .font(.headline)
                            .foregroundStyle(Color.onRibbon)
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
                .opacity(risen ? 1 : 0)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Inside the safe area on every edge, however the system reports it: on Ari's folded Duo the
            // status column was a full-height trailing inset, and a hero centred on the whole paper ran
            // its Sign In button underneath it.
            .background {
                // The launch screen centres its mark in the safe area; so does the first frame here.
                GeometryReader { geo in
                    Color.paper
                        .ignoresSafeArea()
                        .onGeometryChange(for: CGFloat.self) { _ in geo.frame(in: .global).midY } action: { screenCenter = $0 }
                }
            }
            .navigationDestination(isPresented: $signingIn) { SignInFlow() }
        }
        .task { await app.prepareSignIn() }
        .task {
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.3)) {
                    opened = true
                    risen = true
                }
                return
            }
            // The launch screen's closed gatefold opens in place, then rises to make room for the words.
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.spring(duration: 1.1, bounce: 0.12)) { opened = true }
            try? await Task.sleep(for: .milliseconds(750))
            withAnimation(.spring(duration: 0.7, bounce: 0.1)) { risen = true }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: opened)
    }
}

/// The app's mark: a folded sheet whose two panels swing open around a ribbon.
struct GatefoldMark: View {
    static let size = CGSize(width: 180, height: 150)
    var opened: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / 3
            let h = geo.size.height
            ZStack {
                // Centre panel with a ribbon.
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.surface)
                    .frame(width: w, height: h)
                    .overlay(alignment: .top) {
                        RibbonShape().fill(Color.ribbon).frame(width: w * 0.2, height: h * 0.42)
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
                colors: [Color(light: 0xF2F2F7, dark: 0x1C1C1E), Color(light: 0xE5E5EA, dark: 0x2C2C2E)],
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
    /// Signing in again after the Cloud let the sign-in lapse: the email is known.
    var prefilledEmail: String?
    var onDone: (() -> Void)?

    private enum Step: Hashable { case email, store, password }

    @State private var step: Step = .email
    @State private var email = ""
    @State private var password = ""
    @State private var stores: [CloudStore] = []
    @State private var store: CloudStore?
    @State private var working = false
    @State private var error: String?
    @State private var failures = 0
    /// The gentle word under the email field, once he has paused on (or tried to send) an address that can't be one.
    @State private var emailHint: EmailCheck.Problem?
    @State private var passwordFocused = false
    /// Live UI tests: what the debug password fill did (never the password).
    @State private var debugFill = ""
    @FocusState private var focused: Bool

    #if DEBUG
    private func fillFromLiveTestDriver() {
        guard let path = ProcessInfo.processInfo.environment["GATEFOLD_LIVE_CREDENTIAL_FILE"] else {
            debugFill = "no-path"; return
        }
        let file = URL(filePath: path)
        do {
            password = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .newlines)
            debugFill = password.isEmpty ? "empty" : "filled"
        } catch {
            debugFill = "unreadable: \((error as NSError).domain) \((error as NSError).code)"
        }
        try? FileManager.default.removeItem(at: file)
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Back lives in the page, above the title, where the eye already is.
            Button(action: back) {
                Label("Back", systemImage: "chevron.left")
                    .font(.body.weight(.medium))
                    .labelStyle(.titleAndIcon)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ribbon)
            .padding(.bottom, -14)
            .accessibilityIdentifier("signIn.back")
            Text(title)
                .font(.display(.largeTitle, weight: .bold))
                .foregroundStyle(Color.ink)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .foregroundStyle(Color.secondaryInk)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
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
                if let emailHint {
                    Label(Self.hint(for: emailHint), systemImage: "envelope.badge")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryInk)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, -12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .accessibilityIdentifier("signIn.emailHint")
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
                PasswordField(text: $password, isFocused: $passwordFocused, onSubmit: next)
                    .padding(.vertical, 2)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.ink.opacity(0.25)).frame(height: 1) }
                    .modifier(Shake(amount: CGFloat(failures)))
                #if DEBUG
                if LaunchOptions.isUITest {
                    // Live UI tests only: the driver writes the test account's password to a private file and
                    // passes its path; it's read into the field and deleted, never typed or logged. This
                    // reports what happened (never the password).
                    Text(debugFill)
                        .font(.caption2)
                        .opacity(0.02)
                        .accessibilityIdentifier("debug.fillPassword")
                        .onAppear(perform: fillFromLiveTestDriver)
                }
                #endif
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityIdentifier("signIn.error")
            }
            Spacer()
            if step != .store {
                Button(action: next) {
                    ZStack {
                        Text(step == .password ? "Sign In" : "Continue").opacity(working ? 0 : 1)
                            .foregroundStyle(Color.onRibbon)
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
        .animation(.easeOut(duration: 0.25), value: emailHint)
        // A gentle word, not a scolding: it waits until he pauses typing, and leaves the moment the address is fine.
        .task(id: email) {
            guard step == .email else { return }
            let problem = email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : EmailCheck.problem(email)
            if problem == nil { emailHint = nil; return }
            if emailHint != nil { emailHint = problem; return }
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            emailHint = problem
        }
        .sensoryFeedback(.error, trigger: failures)
        .onAppear {
            if let prefilledEmail, !prefilledEmail.isEmpty, email.isEmpty { email = prefilledEmail }
            focusSoon()
        }
        // The keyboard comes up once the new step has landed, not mid-transition.
        .onChange(of: step) { _, _ in focusSoon() }
        .task { await app.prepareSignIn() }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    private func focusSoon() {
        focused = false
        passwordFocused = false
        guard step != .store else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            if step == .password { passwordFocused = true } else { focused = true }
        }
    }

    /// The hint for each slip, kind and a little playful.
    static func hint(for problem: EmailCheck.Problem) -> String {
        switch problem {
        case .space: "Emails don't do spaces, and one is hiding in there."
        case .missingAt: "That one's missing its @. Emails look like name@example.com."
        case .tooManyAts: "One @ is plenty: an email only gets the one."
        case .missingName: "Something goes before the @: your name, usually."
        case .missingDomain: "Nearly! It just needs the part after the @, like example.com."
        case .missingDot: "The part after the @ needs a dot, like mendelow.me."
        }
    }

    private func back() {
        error = nil
        switch step {
        case .email: dismiss()
        case .store: withAnimation(Motion.open) { step = .email }
        case .password: withAnimation(Motion.open) { step = stores.count > 1 ? .store : .email }
        }
    }

    private var title: String {
        switch step {
        case .email: "Sign In"
        case .store: "Which Store?"
        case .password: "Password"
        }
    }

    private var subtitle: String {
        switch step {
        case .email: "Your PocketBook Cloud email: the same one your InkPad knows you by."
        case .store: "\(email) has a shelf in more than one PocketBook store. Which one holds your books?"
        case .password: "For \(email)\(store.map { " at \($0.name)" } ?? ""). One more step and your shelf comes over."
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
        if step == .email, let problem = EmailCheck.problem(email) {
            // Never sent, never spun: say what's off, right away.
            emailHint = problem
            return
        }
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                switch step {
                case .email:
                    stores = try await app.sync.stores(forEmail: email.trimmingCharacters(in: .whitespacesAndNewlines))
                    if stores.count == 1 {
                        store = stores[0]
                        step = .password
                    } else if stores.isEmpty {
                        throw CloudError.noAccount
                    } else {
                        step = .store
                    }
                case .password:
                    guard let store else { return }
                    let account = try await app.sync.signIn(email: email, password: password, store: store)
                    await app.didSignIn(account)
                    onDone?()
                case .store:
                    break
                }
            } catch {
                // Called off (the sheet closed): nothing to say.
                guard let message = FriendlyError.message(for: error) else { return }
                failures += 1
                self.error = message
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
