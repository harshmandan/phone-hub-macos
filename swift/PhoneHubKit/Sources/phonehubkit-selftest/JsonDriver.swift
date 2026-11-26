import Foundation
import PhoneHubKit

/// Machine-readable driver for the `phonehub … json` action: emits `EVENT <json>`
/// lines on stdout (status, notifications, photos) and reads one command per line
/// from stdin (ring / dismiss <id> / reply <id> <text> / photos). The menu-bar app
/// spawns the CLI in this mode and speaks this protocol.
enum JsonDriver {
    static func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        print("EVENT \(s)")
        fflush(stdout)
    }

    static func attach(_ client: PhoneHubClient, photoDir: String) {
        client.fetchPhotos = true
        client.photoDir = photoDir
        client.onSnapshot = { snap in
            emit(["type": "status", "battery": snap.battery as Any, "charging": snap.charging,
                  "signalBars": snap.signalBars as Any, "carrier": snap.carrier,
                  "android": snap.androidVersion as Any, "cameraRoll": snap.cameraRollGranted,
                  "isUpdate": snap.isUpdate])
            for n in snap.notifications {
                emit(["type": "notification", "id": "\(n.id)", "app": n.app,
                      "title": n.title, "text": n.text, "canReply": n.canReply])
            }
            for id in snap.removedIds { emit(["type": "removed", "id": "\(id)"]) }
        }
        client.onPhotos = { photos in
            for p in photos {
                let thumb = p.thumbnail != nil
                    ? "\(photoDir)/\(((p.fileName.isEmpty ? p.key : p.fileName) as NSString).deletingPathExtension).thumb.\(p.thumbIsPng ? "png" : "jpg")"
                    : ""
                emit(["type": "photo", "key": p.key, "fileName": p.fileName, "mime": p.mime,
                      "sizeKB": "\(p.sizeBytes / 1024)", "thumb": thumb])
            }
        }
        client.onDownloaded = { key, path in
            emit(["type": "downloaded", "key": key, "path": path])
        }
        // stdin command loop (one command per line).
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard let cmd = parts.first else { continue }
                DispatchQueue.main.async {
                    switch cmd {
                    case "ring":
                        client.sendPhoneHub(PhoneHub.ringDevice(on: true), label: "ring")
                    case "dismiss" where parts.count >= 2:
                        if let id = Int64(parts[1]) { client.sendPhoneHub(PhoneHub.dismissNotification(id: id), label: "dismiss") }
                    case "reply" where parts.count >= 3:
                        if let id = Int64(parts[1]) { client.sendPhoneHub(PhoneHub.inlineReply(id: id, text: parts[2]), label: "reply") }
                    case "photos":
                        client.sendPhoneHub(PhoneHub.fetchCameraRollItems(max: 12), label: "photos")
                    case "download" where parts.count >= 2:
                        client.downloadPhoto(key: parts.dropFirst().joined(separator: " "))
                    default: break
                    }
                }
            }
        }
    }
}
