import Foundation
import SwiftUI
import UIKit

struct Avatar2DView: View {
    let measurements: Measurements
    let appearance: Appearance
    let fitness: Double
    var facePhoto: UIImage? = nil

    var body: some View {
        GeometryReader { geo in
            let H = geo.size.height
            let u = H / CGFloat(max(measurements.heightCm, 1))
            let bmi = measurements.bmi
            let thick = min(max(0.80 + (bmi - 18.5) * 0.055, 0.75), 1.70)
            let muscle = 1.0 + 0.30 * fitness

            let skinIndex = min(max(appearance.skinTone, 0), Appearance.skinTones.count - 1)
            let hairIndex = min(max(appearance.hairColor, 0), Appearance.hairColors.count - 1)
            let outfitIndex = min(max(appearance.outfitColor, 0), Appearance.outfitColors.count - 1)
            let skin = hexColor(Appearance.skinTones[skinIndex].1)
            let hair = hexColor(Appearance.hairColors[hairIndex].1)
            let outfit = hexColor(Appearance.outfitColors[outfitIndex].1)

            let headW = CGFloat(measurements.headCm) * u * 0.9
            let neckW = CGFloat(measurements.neckCm) * u * 0.5
            let shoulderW = min(CGFloat(measurements.shoulderCm) * u, geo.size.width * 0.8) * thick
            let waistW = CGFloat(measurements.waistCm) * u * thick
            let armW = CGFloat(measurements.armCm) * u * 0.16 * muscle
            let legW = CGFloat(measurements.hipCm) * u * 0.20 * muscle
            let legH = CGFloat(measurements.legCm) * u
            let torsoH = H - legH - headW * 1.15 - neckW * 0.4

            ZStack {
                Circle()
                    .stroke(Theme.accent.opacity(0.25), lineWidth: 1.5)
                    .frame(width: max(shoulderW, legW * 2.6) * 1.7)

                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(skin)
                            .frame(width: headW, height: headW * 1.15)
                        if let facePhoto {
                            // volto dalla galleria (Memoji o selfie): copre la testa,
                            // il cappello di capelli parametrico resta disegnato solo senza foto
                            Image(uiImage: facePhoto)
                                .resizable()
                                .scaledToFill()
                                .frame(width: headW * 1.02, height: headW * 1.02)
                                .clipShape(Circle())
                                .offset(y: headW * 0.04)
                        } else {
                            Circle()
                                .fill(hair)
                                .frame(width: headW * 1.02, height: headW * 0.62)
                                .offset(y: -headW * 0.28)
                        }
                    }
                    .frame(height: headW * 1.15)
                    Rectangle()
                        .fill(skin)
                        .frame(width: neckW, height: neckW * 0.4)
                    RoundedRectangle(cornerRadius: shoulderW * 0.18, style: .continuous)
                        .fill(outfit)
                        .frame(width: shoulderW, height: torsoH * 0.62)
                    RoundedRectangle(cornerRadius: waistW * 0.2, style: .continuous)
                        .fill(outfit.opacity(0.85))
                        .frame(width: waistW, height: torsoH * 0.38)
                    HStack(spacing: legW * 0.9) {
                        RoundedRectangle(cornerRadius: legW * 0.4, style: .continuous)
                            .fill(outfit.opacity(0.7))
                            .frame(width: legW, height: legH)
                        RoundedRectangle(cornerRadius: legW * 0.4, style: .continuous)
                            .fill(outfit.opacity(0.7))
                            .frame(width: legW, height: legH)
                    }
                }

                HStack(spacing: shoulderW - armW * 2) {
                    RoundedRectangle(cornerRadius: armW * 0.5, style: .continuous)
                        .fill(skin)
                        .frame(width: armW, height: torsoH * 0.9 + headW * 0.5)
                    Spacer()
                    RoundedRectangle(cornerRadius: armW * 0.5, style: .continuous)
                        .fill(skin)
                        .frame(width: armW, height: torsoH * 0.9 + headW * 0.5)
                }
                .padding(.top, headW * 1.15 + neckW * 0.4)
            }
        }
        .background(Color.black)
    }
}
