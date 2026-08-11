#!/usr/bin/env swift
//
// 生成 App 图标。
//
//   swift Scripts/generate-app-icon.swift
//
// 画的是网页版的品牌标（`filego/src/web/app.client.css` 的 `.brand-mark`）：
// 一枚微微左倾的圆角块，顶上探出一小截当文件夹的翻盖，中间一个 ↗。
// 端上同一枚标的 UIKit 版本在 `filego/Common/DesignSystem/BrandMarkView.swift`，
// 两处的几何是同一套数，改一边记得改另一边。
//
// 刻意用脚本而不是手工导一张 PNG：改配色改尺寸时不用回去翻设计稿，
// 也免得仓库里躺着一张没人说得清怎么来的图。做法与 `filego/generate_r_swift.py` 一致。

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - 设计 token（与 DesignSystem.swift 同源）

let ink = CGColor(srgbRed: 0x14 / 255, green: 0x20 / 255, blue: 0x1B / 255, alpha: 1)
let lime = CGColor(srgbRed: 0xB9 / 255, green: 0xF4 / 255, blue: 0x4C / 255, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

/// 网页 `.brand-mark` 的基准尺寸。下面所有部件都是这套数按同一个系数放大，
/// 各自取整会让圆角与「舌」的比例走样。
enum Mark {
    static let bodyWidth: CGFloat = 35
    static let bodyHeight: CGFloat = 30
    static let bodyRadius: CGFloat = 8
    static let tabWidth: CGFloat = 16
    static let tabHeight: CGFloat = 9
    static let tabLeft: CGFloat = 3
    /// 「舌」顶端相对主体顶边再往上 5。
    static let tabRise: CGFloat = 5
    static let tabRadius: CGFloat = 5
    static let arrowFontSize: CGFloat = 19
    static let tilt: CGFloat = -3 * .pi / 180

    /// 外接盒是正方形：宽 35，高 30 + 探出的 5。
    static let side: CGFloat = 35
}

let canvas: CGFloat = 1024
/// 品牌标占画布的比例。-3° 旋转会把外接盒撑大约 5%，这个比例下留白仍然充足。
let markFraction: CGFloat = 0.62

// MARK: - 绘制

struct Variant {
    let name: String
    /// nil 表示透明底。深色与色调变体必须留透明，系统会在底下垫自己的渐变；
    /// 自带背景会在桌面上多出一个方块边。
    let background: CGColor?
    let folder: CGColor
    /// 默认图必须不透明——App Store 会拒收带 alpha 的图标，所以那一版的箭头
    /// 不能真打洞，只能用底色填。透明底的两版才用 `.destinationOut` 真镂空。
    let arrowFill: CGColor?
}

let variants = [
    Variant(name: "icon-1024", background: lime, folder: ink, arrowFill: lime),
    Variant(name: "icon-1024-dark", background: nil, folder: lime, arrowFill: nil),
    Variant(name: "icon-1024-tinted", background: nil, folder: white, arrowFill: nil)
]

func roundedPath(_ rect: CGRect, radius: CGFloat, topOnly: Bool = false) -> CGPath {
    if topOnly {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX + radius, y: rect.maxY),
            radius: radius
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - radius),
            radius: radius
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// ↗ 的矢量路径。
///
/// 刻意**不用字体里的 U+2197**：字形的粗细由字重档位决定，在 1024 的画布上
/// 要么细得发虚要么撑不到想要的比例，而且不同系统版本的 SF 字形还会变。
///
/// 画法是先在「水平向右」的坐标系里摆一根杆加一个三角头——这样杆和头的接缝
/// 是一条直线，天然严丝合缝——最后整体转 45° 变成右上。直接在斜向上拼两段
/// 路径的话，接缝处必然错位。
func arrowPath(in box: CGRect) -> CGPath {
    let length = box.width * sqrt(2) * 0.86   // 沿对角线铺开，留一点边距
    // 头别做大：↗ 是个指示符号不是纸飞机，头一宽整枚标就从「文件夹」变成「发送」。
    let shaftThickness = length * 0.17
    let headLength = length * 0.27
    let headHalfWidth = length * 0.185

    let path = CGMutablePath()
    // 杆：从尾端一直伸到三角底边下面一点，避免两者之间露出缝。
    path.addRect(CGRect(
        x: -length / 2,
        y: -shaftThickness / 2,
        width: length - headLength + shaftThickness * 0.5,
        height: shaftThickness
    ))
    // 头：等腰三角形，尖端在正右。
    path.move(to: CGPoint(x: length / 2 - headLength, y: -headHalfWidth))
    path.addLine(to: CGPoint(x: length / 2, y: 0))
    path.addLine(to: CGPoint(x: length / 2 - headLength, y: headHalfWidth))
    path.closeSubpath()

    var transform = CGAffineTransform(translationX: box.midX, y: box.midY)
        .rotated(by: .pi / 4)
    return path.copy(using: &transform) ?? path
}

func render(_ variant: Variant) -> CGImage {
    let size = Int(canvas)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("无法创建 1024×1024 的 sRGB 位图上下文")
    }

    if let background = variant.background {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    }

    let scale = canvas * markFraction / Mark.side
    let bodyW = Mark.bodyWidth * scale
    let bodyH = Mark.bodyHeight * scale
    let markW = bodyW
    let markH = bodyH + Mark.tabRise * scale

    // 以外接盒中心为原点旋转，整枚标才是绕自己转，而不是绕画布左下角甩出去。
    context.saveGState()
    context.translateBy(x: canvas / 2, y: canvas / 2)
    context.rotate(by: Mark.tilt)
    context.translateBy(x: -markW / 2, y: -markH / 2)

    let body = CGRect(x: 0, y: 0, width: bodyW, height: bodyH)
    let tab = CGRect(
        x: Mark.tabLeft * scale,
        // CoreGraphics 的 y 向上，网页的 top 向下：舌在主体**上方**探出。
        y: bodyH - (Mark.tabHeight - Mark.tabRise) * scale,
        width: Mark.tabWidth * scale,
        height: Mark.tabHeight * scale
    )

    context.setFillColor(variant.folder)
    // 舌先画：它与主体同色且相互重叠，谁先谁后不影响外观，但先画舌可以让
    // 主体的圆角盖住舌的下半截，转角处不会露出直角。
    context.addPath(roundedPath(tab, radius: Mark.tabRadius * scale, topOnly: true))
    context.fillPath()
    context.addPath(roundedPath(body, radius: Mark.bodyRadius * scale))
    context.fillPath()

    // 箭头在主体里居中。网页那里是 19px 的字，字形只占字号的六成左右，
    // 这里画的是实心路径，按 0.9 折算才是同样的视觉体量。
    let arrowSide = Mark.arrowFontSize * scale * 0.9
    let arrowBox = CGRect(
        x: body.midX - arrowSide / 2,
        y: body.midY - arrowSide / 2,
        width: arrowSide,
        height: arrowSide
    )
    // 网页把整块转了 -3°，又把里面的箭头转回 +3°，让箭头保持正着。
    context.saveGState()
    context.translateBy(x: arrowBox.midX, y: arrowBox.midY)
    context.rotate(by: -Mark.tilt)
    context.translateBy(x: -arrowBox.midX, y: -arrowBox.midY)
    if let fill = variant.arrowFill {
        context.setFillColor(fill)
        context.addPath(arrowPath(in: arrowBox))
        context.fillPath()
    } else {
        context.setBlendMode(.destinationOut)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(arrowPath(in: arrowBox))
        context.fillPath()
        context.setBlendMode(.normal)
    }
    context.restoreGState()

    context.restoreGState()

    guard let image = context.makeImage() else { fatalError("位图渲染失败") }
    return image
}

// MARK: - 落盘

let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let iconSet = projectRoot
    .appendingPathComponent("filego/Assets.xcassets/AppIcon.appiconset")

for variant in variants {
    let image = render(variant)
    let url = iconSet.appendingPathComponent("\(variant.name).png")
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: canvas, height: canvas)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        fatalError("PNG 编码失败：\(variant.name)")
    }
    try data.write(to: url)
    print("[icon] \(url.lastPathComponent) \(data.count / 1024) KB")
}
