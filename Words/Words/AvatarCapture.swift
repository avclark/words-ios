import SwiftUI
import PhotosUI
import Supabase

// MARK: - Camera capture

/// SwiftUI has no native camera UI — this wraps UIImagePickerController's
/// camera. Requires NSCameraUsageDescription (Words-Info.plist).
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Crop

/// Square/circle crop before upload: pinch to zoom, drag to position,
/// the circle shows exactly what the avatar will be. Output is rendered
/// at a capped size (512²) so uploads stay small.
struct AvatarCropView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let image: UIImage
    let onCrop: (UIImage) -> Void

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - 48

            VStack(spacing: 20) {
                Text("MOVE AND SCALE")
                    .font(theme.typography.sectionTitle)
                    .kerning(1)
                    .foregroundStyle(theme.chrome.ink.opacity(0.4))

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .scaleEffect(zoom)
                        .offset(offset)
                }
                .frame(width: side, height: side)
                .clipped()
                // The circle preview: everything outside dims; the crop
                // itself is the full square (displayed as a circle
                // everywhere in the app).
                .overlay(
                    Circle()
                        .strokeBorder(theme.chrome.ink.opacity(0.9), lineWidth: 2)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height)
                        }
                        .onEnded { _ in
                            offset = clampedOffset(offset, side: side)
                            lastOffset = offset
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            zoom = min(4, max(1, lastZoom * value.magnification))
                        }
                        .onEnded { _ in
                            lastZoom = zoom
                            offset = clampedOffset(offset, side: side)
                            lastOffset = offset
                        }
                )

                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(theme.typography.font(14, .semibold))
                            .foregroundStyle(theme.chrome.buttonSecondaryText)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Capsule().fill(theme.chrome.buttonSecondaryFill))
                    }
                    Button {
                        onCrop(cropped(side: side))
                        dismiss()
                    } label: {
                        Text("Use Photo")
                            .font(theme.typography.font(14, .heavy))
                            .foregroundStyle(theme.chrome.buttonPrimaryText)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Capsule().fill(theme.chrome.buttonPrimary))
                    }
                }
                .padding(.horizontal, theme.metrics.screenHPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.chrome.screenBackground.ignoresSafeArea())
        .presentationBackground(theme.chrome.screenBackground)
    }

    /// Keep the image covering the crop square.
    private func clampedOffset(_ proposed: CGSize, side: CGFloat) -> CGSize {
        let fill = baseFill(side: side)
        let drawn = CGSize(width: image.size.width * fill * zoom,
                           height: image.size.height * fill * zoom)
        let maxX = max(0, (drawn.width - side) / 2)
        let maxY = max(0, (drawn.height - side) / 2)
        return CGSize(width: min(maxX, max(-maxX, proposed.width)),
                      height: min(maxY, max(-maxY, proposed.height)))
    }

    /// scaledToFill's base scale inside the square.
    private func baseFill(side: CGFloat) -> CGFloat {
        max(side / max(image.size.width, 1), side / max(image.size.height, 1))
    }

    /// Reproduce the on-screen transform into a 512² render — what you
    /// see in the circle is exactly what uploads.
    private func cropped(side: CGFloat) -> UIImage {
        let out: CGFloat = 512
        let scale = out / side
        let fill = baseFill(side: side) * zoom
        let drawn = CGSize(width: image.size.width * fill,
                           height: image.size.height * fill)
        let origin = CGPoint(x: (side - drawn.width) / 2 + offset.width,
                             y: (side - drawn.height) / 2 + offset.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: out, height: out), format: format)
            .image { _ in
                image.draw(in: CGRect(x: origin.x * scale,
                                      y: origin.y * scale,
                                      width: drawn.width * scale,
                                      height: drawn.height * scale))
            }
    }
}

// MARK: - Upload

/// The one owned storage slot per user: avatars/{lowercased-uid}.jpg.
/// A new upload overwrites the old (upsert) so nothing orphans.
enum AvatarUploader {
    static func path(for userID: UUID) -> String {
        "\(userID.uuidString.lowercased()).jpg"
    }

    /// Uploads a cropped avatar (jpeg ~0.8) and returns the public URL
    /// with a cache-busting stamp — assigning it to the profile makes
    /// every screen refresh past any cached older photo.
    static func upload(_ image: UIImage, for userID: UUID) async throws -> String {
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw URLError(.cannotCreateFile)
        }
        let slot = path(for: userID)
        _ = try await SupabaseService.client.storage
            .from("avatars")
            .upload(slot, data: data,
                    options: FileOptions(cacheControl: "3600",
                                         contentType: "image/jpeg",
                                         upsert: true))
        let url = try SupabaseService.client.storage
            .from("avatars")
            .getPublicURL(path: slot)
        return "\(url.absoluteString)?t=\(Int(Date().timeIntervalSince1970))"
    }

    static func removePhoto(for userID: UUID) async throws {
        _ = try await SupabaseService.client.storage
            .from("avatars")
            .remove(paths: [path(for: userID)])
    }
}
