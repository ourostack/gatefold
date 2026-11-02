import Testing
import UIKit
@testable import Gatefold

/// The curl holds the old page until the new one has painted; these are the pages that haven't.
struct PageSignatureTests {
    private func image(_ fill: UIColor, lines: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 240, height: 320)).image { context in
            fill.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
            guard lines else { return }
            UIColor.darkGray.setFill()
            for row in stride(from: 20, to: 300, by: 18) { context.fill(CGRect(x: 20, y: row, width: 200, height: 6)) }
        }
    }

    private let vellum = PageSignature.rgb(UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1))

    @Test func paperWithNothingOnItIsBare() {
        let page = PageSignature(image(UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1), lines: false))!
        #expect(page.isBare(paper: vellum))
    }

    @Test func aWhiteLoadingPageIsBareOnAnyPaper() {
        let page = PageSignature(image(.white, lines: false))!
        #expect(page.isBare(paper: vellum))
    }

    @Test func aPageOfTextIsNot() {
        let page = PageSignature(image(.white, lines: true))!
        #expect(!page.isBare(paper: vellum))
    }
}
