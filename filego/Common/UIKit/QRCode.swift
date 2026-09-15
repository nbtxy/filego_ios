import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/**
 二维码。CoreImage 自带，不引入任何依赖。

 `CIQRCodeGenerator` 吐出的原图边长只有二十几像素——一个模块一个像素。直接塞进
 `UIImageView` 拉伸会被默认的双线性插值糊掉边界，相机就认不出来了，所以这里先用
 `CGAffineTransform` 把 `CIImage` 整数倍放大再渲染：放大发生在光栅化之前，边界是硬的。
 */
enum QRCode {
    /// 纠错档。`M` 能容 15% 的破损，是尺寸和容错之间的常用折中；地址串很短，
    /// 升到 `Q`/`H` 只会白白让模块变密。
    private static let correctionLevel = "M"

    private static let context = CIContext()

    /**
     把一段文本渲染成二维码。

     `side` 是期望的点数边长，实际输出会取不小于它的整数倍放大，避免非整数缩放
     在模块边界上产生半透明像素。
     */
    static func image(for text: String, side: CGFloat = 512) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        // 二维码的字节模式按 ISO-8859-1 解，URL 全是 ASCII，落在两者一致的范围里。
        filter.message = Data(text.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }

        let scale = max(1, (side / output.extent.width).rounded(.up))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
