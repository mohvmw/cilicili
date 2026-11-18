import SwiftUI

struct HomeFeedLayoutMetrics {
    let mode: HomeFeedLayout
    let doubleColumns: [GridItem]
    let feedColumns: [GridItem]
    let feedSpacing: CGFloat
    let feedHorizontalPadding: CGFloat
    let singleColumnHorizontalPadding: CGFloat
    let singleColumnFixedCoverSize: CGSize?
    let doubleColumnFixedCoverSize: CGSize?
    let borderedSingleColumnCoverSize: CGSize?

    init(
        mode: HomeFeedLayout,
        containerWidth: CGFloat,
        standardHorizontalInset: CGFloat = 20
    ) {
        self.mode = mode
        // 双列边距/间距向官方 B 站看齐：边距 20→6、列间距 14→6，
        // 封面宽 (390-12-6)/2 = 186pt（+10.7%），高 16:9 不变。
        let doubleColumnSpacing: CGFloat = mode == .borderedDoubleColumn ? 12 : 6
        let doubleColumnCoverHeightRatio: CGFloat = mode == .borderedDoubleColumn ? 10 / 16 : 9 / 16
        doubleColumns = [
            GridItem(.flexible(), spacing: doubleColumnSpacing),
            GridItem(.flexible(), spacing: doubleColumnSpacing)
        ]
        singleColumnHorizontalPadding = standardHorizontalInset

        switch mode {
        case .singleColumn, .borderedSingleColumn:
            feedColumns = [
                GridItem(.flexible(minimum: 0), spacing: 0)
            ]
            feedSpacing = 0
            feedHorizontalPadding = 0
        case .doubleColumn:
            feedColumns = doubleColumns
            feedSpacing = 18
            feedHorizontalPadding = 6
        case .borderedDoubleColumn:
            feedColumns = doubleColumns
            feedSpacing = 18
            feedHorizontalPadding = standardHorizontalInset
        }

        let singleWidth = containerWidth - singleColumnHorizontalPadding * 2
        if singleWidth > 0 {
            singleColumnFixedCoverSize = CGSize(width: singleWidth, height: singleWidth * 9 / 16)
        } else {
            singleColumnFixedCoverSize = nil
        }

        let doubleWidth = (containerWidth - (feedHorizontalPadding * 2) - doubleColumnSpacing) / 2
        if doubleWidth > 0 {
            doubleColumnFixedCoverSize = CGSize(width: doubleWidth, height: doubleWidth * doubleColumnCoverHeightRatio)
        } else {
            doubleColumnFixedCoverSize = nil
        }

        if singleWidth > 0 {
            borderedSingleColumnCoverSize = CGSize(width: 140, height: 88)
        } else {
            borderedSingleColumnCoverSize = nil
        }
    }
}
