import CoreGraphics
import ImageIO
import LADThumbnailSupport
import QuickLookThumbnailing

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            guard let data = try ProjectThumbnailReader.imageData(in: request.fileURL),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  request.maximumSize.width > 0, request.maximumSize.height > 0 else {
                handler(nil, nil)
                return
            }
            let reply = QLThumbnailReply(contextSize: request.maximumSize, drawing: { context in
                ProjectThumbnailDrawing.draw(image, in: context)
            })
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
