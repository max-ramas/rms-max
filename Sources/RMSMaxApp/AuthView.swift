import SwiftUI
import RMSMaxCore
import CoreImage.CIFilterBuiltins

struct AuthView: View {
    @EnvironmentObject private var store: AppStore
    @State private var phone = "+7"
    @State private var code = ""
    @State private var password = ""
    @State private var firstName = ""
    @State private var lastName = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("RMS MAX")
                    .font(.largeTitle.bold())
                Text("Нативный клиент без телеметрии для macOS и iOS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(spacing: 16) {
                    switch store.authStep {
                    case .phoneInput:
                        TextField("Номер телефона (+7...)", text: $phone)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .keyboardType(.phonePad)
                            #endif
                        Toggle("Мобильный TLS-протокол (api2.oneme.ru)", isOn: $store.useMobileTransport)
                            .font(.subheadline)
                        Button {
                            Task { await store.requestPhoneCode(phone: phone) }
                        } label: {
                            if store.isBusy { ProgressView().controlSize(.small) }
                            else { Text("Получить код").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isBusy)
                        HStack {
                            Button("Войти звонком") { Task { await store.startCallOutLogin(phone: phone) } }
                                .disabled(store.isBusy)
                            Spacer()
                            Button("Войти по QR-коду") { Task { await store.startQRLogin() } }
                                .disabled(store.isBusy)
                        }
                        .font(.subheadline)

                    case .qrLogin(let link):
                        Text("Отсканируйте код в приложении MAX на телефоне, где вы уже вошли: Настройки → Устройства → Подключить устройство.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        QRCodeImage(text: link)
                            .frame(width: 220, height: 220)
                        Text("Код обновится автоматически").font(.caption).foregroundStyle(.secondary)
                        Button("Назад") { store.cancelTrackLogin() }

                    case .callOutLogin(let targetPhone, let callNumber):
                        if let callNumber {
                            Text("Позвоните с номера \(targetPhone) на этот номер — звонок бесплатный и сразу сбросится:")
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                            Link("+" + callNumber.trimmingCharacters(in: CharacterSet(charactersIn: "+")),
                                 destination: URL(string: "tel:+" + callNumber.filter(\.isNumber)) ?? URL(string: "tel:")!)
                                .font(.title2.bold().monospacedDigit())
                            Text("Ждём звонка…").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ProgressView("Готовим номер для звонка…")
                        }
                        Button("Назад") { store.cancelTrackLogin() }

                    case .codeInput(let targetPhone):
                        Text("Код отправлен на \(targetPhone)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField(
                            store.authCodeLength.map { "Код из SMS (\($0) цифр)" } ?? "Код из SMS / звонка",
                            text: $code
                        )
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            #endif
                            .onSubmit { Task { await store.verifyCode(code) } }
                        HStack {
                            Button("Назад") { code = ""; store.authStep = .phoneInput }
                            Button("Отправить снова") { Task { await store.resendPhoneCode() } }
                                .disabled(store.isBusy)
                            Spacer()
                            Button("Подтвердить") {
                                Task { await store.verifyCode(code) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isBusy)
                        }

                    case .password2FA(let trackId, let hint):
                        Text("Требуется облачный пароль (2FA)")
                            .font(.headline)
                        if let hint, !hint.isEmpty {
                            Text("Подсказка: \(hint)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        SecureField("Облачный пароль", text: $password)
                            .textFieldStyle(.roundedBorder)
                        Button("Войти") {
                            Task { await store.verify2FAPassword(password, trackId: trackId) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isBusy)

                    case .registration:
                        Text("Завершение регистрации")
                            .font(.headline)
                        TextField("Имя", text: $firstName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Фамилия (необязательно)", text: $lastName)
                            .textFieldStyle(.roundedBorder)
                        Button("Создать профиль") {
                            Task {
                                await store.completeRegistration(
                                    firstName: firstName,
                                    lastName: lastName.isEmpty ? nil : lastName
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isBusy || firstName.trimmingCharacters(in: .whitespaces).isEmpty)

                    case .authenticated:
                        EmptyView()
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: 420)

            Label("Телеметрия отключена, трекеры и IP-пробы вырезаны", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
    }
}

/// QR code for the login link (CoreImage, no network).
private struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            #if os(macOS)
            Image(nsImage: image).interpolation(.none).resizable()
            #else
            Image(uiImage: image).interpolation(.none).resizable()
            #endif
        } else {
            Text(text).font(.caption).textSelection(.enabled)
        }
    }

    #if os(macOS)
    static func render(_ text: String) -> NSImage? {
        guard let cg = cgImage(text) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    #else
    static func render(_ text: String) -> UIImage? {
        cgImage(text).map { UIImage(cgImage: $0) }
    }
    #endif

    private static func cgImage(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
