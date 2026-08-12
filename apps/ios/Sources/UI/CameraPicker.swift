import SwiftUI
import UIKit

/// The camera, as a sheet.
///
/// `PhotosPicker` covers the library and cannot open the camera — it is a
/// picker for things that already exist. So this is `UIImagePickerController`,
/// which is old and deprecated-adjacent but is still the only way to get a
/// single still photo without adopting AVFoundation and building a capture UI.
/// What is here is the whole of it: present, take one picture, hand back a
/// `UIImage`.
///
/// Unlike `PhotosPicker` this needs a permission — `NSCameraUsageDescription`,
/// declared in project.yml. iOS asks on first presentation and this view does
/// not pre-check: `AVCaptureDevice.authorizationStatus` before presenting would
/// mean two prompts to reason about instead of one, and the picker already
/// handles a refusal by showing its own explanation.
///
/// **No camera in the Simulator.** `isAvailable` is false there, which is why
/// the button that presents this is hidden rather than disabled — a permanently
/// dead button on the machine the app is developed on invites somebody to
/// "fix" it.
struct CameraPicker: UIViewControllerRepresentable {
    /// Whether this device can present it at all.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let dismiss: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // `.originalImage` rather than `.editedImage`: editing is off, so
            // the edited key is absent and reading it first would always miss.
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
