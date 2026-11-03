import SwiftUI
import UIKit

/// The sign-in password, with an eye to show or hide it. One UIKit text field that only changes
/// `isSecureTextEntry`, so showing and hiding keeps the keyboard up and every typed character (a SwiftUI
/// `SecureField` swapped for a `TextField` loses focus, and wipes the password on the next keystroke).
/// `.password` content type keeps AutoFill and the strong-password keychain working.
struct PasswordField: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onSubmit: () -> Void
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 8) {
            PasswordTextField(text: $text, isFocused: $isFocused, revealed: revealed, onSubmit: onSubmit)
                .frame(maxWidth: .infinity, minHeight: 30)
                // A UITextField stretches to any height it's offered; keep it one line tall.
                .fixedSize(horizontal: false, vertical: true)
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.body)
                    .foregroundStyle(Color.secondaryInk)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed ? "Hide password" : "Show password")
            .accessibilityIdentifier("signIn.revealPassword")
            .sensoryFeedback(.selection, trigger: revealed)
        }
    }
}

private struct PasswordTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var revealed: Bool
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.textContentType = .password
        field.isSecureTextEntry = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .go
        field.placeholder = "Password"
        field.accessibilityIdentifier = "signIn.password"
        field.font = .preferredFont(forTextStyle: .title3)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = UIColor(Color.ink)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if field.isSecureTextEntry == revealed {
            // Toggling secure entry keeps first responder; putting the text back keeps the caret at its end
            // (UIKit otherwise draws it where the dots used to end).
            field.isSecureTextEntry = !revealed
            let current = field.text
            field.text = nil
            field.text = current
        }
        if isFocused, !field.isFirstResponder, field.window != nil {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isFocused, field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PasswordTextField
        init(_ parent: PasswordTextField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

        /// A secure field empties itself when typing resumes after it lost focus or was just hidden again.
        /// Apply each edit ourselves so the password is only ever changed by the keys pressed.
        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard field.isSecureTextEntry, let current = field.text, let swap = Range(range, in: current) else { return true }
            let updated = current.replacingCharacters(in: swap, with: string)
            field.text = updated
            parent.text = updated
            return false
        }

        func textFieldDidBeginEditing(_ field: UITextField) { if !parent.isFocused { parent.isFocused = true } }
        func textFieldDidEndEditing(_ field: UITextField) { if parent.isFocused { parent.isFocused = false } }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
