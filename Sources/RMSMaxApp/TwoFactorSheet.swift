// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore

/// Login password (two-factor protection), like the official client's «Пароль»: set, change, remove, optional recovery e-mail.
struct TwoFactorSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var flow: TwoFactorFlow

    init(store: AppStore) { _flow = StateObject(wrappedValue: TwoFactorFlow(store: store)) }

    private enum Step { case loading, status, set, change, remove, emailCode, done(String) }

    @State private var step: Step = .loading
    @State private var info: TwoFactorStatus?
    @State private var current = ""
    @State private var password = ""
    @State private var repeatPassword = ""
    @State private var hint = ""
    @State private var email = ""
    @State private var code = ""
    @State private var codeLength = 0
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .status:
                    statusSection
                case .set:
                    newPasswordFields(title: "Новый пароль")
                    Section("Почта для восстановления (необязательно)") { TextField("name@example.com", text: $email) }
                    actionButton("Включить пароль", enabled: canSave) { await save(newPassword: true) }
                case .change:
                    Section("Текущий пароль") { SecureField("Текущий пароль", text: $current) }
                    newPasswordFields(title: "Новый пароль")
                    actionButton("Сменить пароль", enabled: canSave && !current.isEmpty) { await save(newPassword: false) }
                case .remove:
                    Section {
                        SecureField("Текущий пароль", text: $current)
                    } header: { Text("Удалить пароль") } footer: { Text("Вход в аккаунт снова будет только по коду из SMS.") }
                    actionButton("Удалить пароль", enabled: !current.isEmpty, destructive: true) { await remove() }
                case .emailCode:
                    Section {
                        TextField("Код из письма", text: $code)
                    } header: { Text("Подтвердите почту") } footer: { Text("Код отправлен на \(email)\(codeLength > 0 ? " (\(codeLength) цифр)" : "").") }
                    actionButton("Подтвердить", enabled: !code.isEmpty) { await confirmEmail() }
                case .done(let text):
                    Section { Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.callout) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Пароль для входа")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(isDone ? "Готово" : "Закрыть") { dismiss() } } }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private var isDone: Bool { if case .done = step { return true }; return false }
    private var canSave: Bool { !password.isEmpty && password == repeatPassword }

    @ViewBuilder private var statusSection: some View {
        let on = info?.enabled == true
        Section {
            Label(on ? "Пароль включён" : "Пароль не задан", systemImage: on ? "lock.fill" : "lock.open")
                .foregroundStyle(on ? .green : .secondary)
            if let h = info?.hint, !h.isEmpty { LabeledContent("Подсказка", value: h) }
            if let m = info?.email, !m.isEmpty { LabeledContent("Почта", value: m) }
        } footer: {
            Text(on ? "Пароль запрашивается при входе в аккаунт на новом устройстве, после кода из SMS."
                    : "Пароль защищает вход в аккаунт на новом устройстве: помимо кода из SMS нужно будет ввести его.")
        }
        Section {
            if on {
                Button("Сменить пароль…") { reset(); step = .change }
                Button("Удалить пароль…", role: .destructive) { reset(); step = .remove }
            } else {
                Button("Задать пароль…") { reset(); step = .set }
            }
        }
    }

    @ViewBuilder private func newPasswordFields(title: String) -> some View {
        Section(title) {
            SecureField("Пароль", text: $password)
            SecureField("Повторите пароль", text: $repeatPassword)
            if !repeatPassword.isEmpty && password != repeatPassword { Text("Пароли не совпадают").font(.caption).foregroundStyle(.red) }
            TextField("Подсказка (необязательно)", text: $hint)
        }
    }

    private func actionButton(_ title: String, enabled: Bool, destructive: Bool = false, _ run: @escaping () async -> Void) -> some View {
        Section {
            Button(role: destructive ? .destructive : nil) { Task { busy = true; error = nil; await run(); busy = false } } label: {
                HStack { Text(title); if busy { ProgressView().controlSize(.small) } }.frame(maxWidth: .infinity)
            }
            .disabled(!enabled || busy)
        }
    }

    private func reset() { current = ""; password = ""; repeatPassword = ""; hint = ""; email = ""; code = ""; error = nil }

    private func load() async {
        do { info = try await flow.status(); step = .status }
        catch { self.error = error.localizedDescription; step = .status }
    }

    private func save(newPassword: Bool) async {
        do {
            if !newPassword { try await flow.checkCurrent(current) }
            try await flow.validate(password: password, hint: hint)
            let mail = email.trimmingCharacters(in: .whitespaces)
            if newPassword, !mail.isEmpty {
                codeLength = try await flow.sendEmailCode(mail)
                email = mail
                step = .emailCode
                return
            }
            if newPassword { try await flow.enable(password: password, hint: hint, withEmail: false) }
            else { try await flow.change(password: password, hint: hint) }
            step = .done(newPassword ? "Пароль включён." : "Пароль изменён.")
        } catch { self.error = error.localizedDescription }
    }

    private func confirmEmail() async {
        do {
            try await flow.confirmEmail(code: code)
            try await flow.enable(password: password, hint: hint, withEmail: true)
            step = .done("Пароль включён, почта подтверждена.")
        } catch { self.error = error.localizedDescription }
    }

    private func remove() async {
        do {
            try await flow.checkCurrent(current)
            try await flow.remove()
            step = .done("Пароль удалён.")
        } catch { self.error = error.localizedDescription }
    }
}
